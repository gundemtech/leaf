//
//  GoogleCalendarCollector+Sync.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — calendarList + per-calendar events.list
//  sync + per-event classification + page persistence. Pure relocation from
//  GoogleCalendarCollector.swift.
//

import Foundation
import GRDB

extension GoogleCalendarCollector {
    /// Build RawEvent rows + UPSERT tracker for typed events on a single
    /// events.list page. Atomic per event (separate writes so a single
    /// malformed payload doesn't abort the whole page).
    struct TrackerUpsert {
        let eventID: String
        let calendarID: String
        let iCalUID: String?
        let eventType: String
        let startMs: Int64
        let endMs: Int64
        let workingLocationType: String?
        let autoDeclineMode: String?
        let chatStatus: String?
    }

    enum ProcessedEvent {
        case observe(rawEvent: RawEvent, upsert: TrackerUpsert?)
        case delete(eventID: String)
        case skip
    }

    // MARK: - calendarList sync

    /// Walk calendarList pages (initial: no syncToken → walk all pages; delta:
    /// just the first page since Google never paginates delta responses to
    /// any practical degree), then diff vs `known_calendars` and prune.
    func syncCalendarList(accessToken: String) async throws {
        let savedCursor: GoogleCalendarSyncTokenStore.CalendarListSyncCursor? = try? database.readSQL { db in
            try GoogleCalendarSyncTokenStore.calendarListSyncToken(in: db)
        }
        let savedToken = savedCursor?.token

        // First call uses savedToken (nil → walk all pages).
        var allItems: [GoogleCalendarAPI.CalendarListEntry] = []
        var nextPage: String? = nil
        var newSyncToken: String? = nil

        repeat {
            // After the first page we stop sending the syncToken — Google's
            // pagination contract is page-token-only for subsequent pages.
            let syncTokenForCall = (nextPage == nil) ? savedToken : nil
            let resp = try await apiClient.calendarListList(
                syncToken: syncTokenForCall,
                pageToken: nextPage,
                accessToken: accessToken
            )
            allItems.append(contentsOf: resp.items)
            nextPage = resp.nextPageToken
            if let s = resp.nextSyncToken {
                newSyncToken = s
            }
        } while nextPage != nil

        // Filter to actually-syncable roles.
        let newKnown =
            allItems
            .filter { Self.syncableAccessRoles.contains($0.accessRole) }
            .map { entry in
                GoogleCalendarSyncTokenStore.KnownCalendar(
                    id: entry.id,
                    summary: entry.summary,
                    summaryOverride: entry.summaryOverride,
                    accessRole: entry.accessRole,
                    primary: entry.primary,
                    colorId: entry.colorId,
                    timeZone: entry.timeZone
                )
            }

        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)

        // Diff vs old known — prune cursors + tracker rows for any removed
        // calendar id.
        let oldKnown =
            (try? database.readSQL { db in
                try GoogleCalendarSyncTokenStore.knownCalendars(in: db)
            }) ?? []
        let removedIDs = Set(oldKnown.map(\.id)).subtracting(Set(newKnown.map(\.id)))

        try database.writeSQL { db in
            for removedID in removedIDs {
                try GoogleCalendarSyncTokenStore.deleteEventsSyncToken(calendarId: removedID, in: db)
                try GoogleCalendarTrackerStore.deleteByCalendarID(removedID, in: db)
            }
            try GoogleCalendarSyncTokenStore.upsertKnownCalendars(newKnown, nowMs: nowMs, in: db)
            if let token = newSyncToken {
                try GoogleCalendarSyncTokenStore.upsertCalendarListSyncToken(
                    token: token,
                    lastFullSyncAtMs: nowMs,
                    nowMs: nowMs,
                    in: db
                )
            }
        }
    }

    // MARK: - Per-calendar events.list sync

    func syncCalendarEvents(
        calendar: GoogleCalendarSyncTokenStore.KnownCalendar,
        accessToken: inout String,
        userDomain: String
    ) async throws {
        // Read saved cursor. `try?` over `readSQL { throws -> EventsSyncCursor? }`
        // collapses to `EventsSyncCursor?` (Swift flattens the inner optional).
        let savedCursor: GoogleCalendarSyncTokenStore.EventsSyncCursor? = try? database.readSQL { db in
            try GoogleCalendarSyncTokenStore.eventsSyncToken(calendarId: calendar.id, in: db)
        }
        let savedToken = savedCursor?.token
        let bootstrap = (savedToken == nil)

        if bootstrap {
            let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
            try database.writeSQL { db in
                try GoogleCalendarSyncTokenStore.markBootstrapInProgress(
                    calendarId: calendar.id,
                    nowMs: nowMs,
                    in: db
                )
            }
        }

        let initialSyncToken: String? = bootstrap ? nil : savedToken
        let bootstrapTimeMin: Date? =
            bootstrap
            ? clock().addingTimeInterval(-Self.bootstrapWindowSec)
            : nil

        var nextPageToken: String? = nil
        var lastSyncToken: String? = nil
        var retriedOn401 = false

        pageLoop: while true {
            // Per Google contract: syncToken + pageToken can co-exist on
            // subsequent pages of an initial bootstrap as well; but to keep
            // semantics simple we only send syncToken on the first page.
            let syncTokenForCall = (nextPageToken == nil) ? initialSyncToken : nil
            let bootstrapTimeMinForCall = (nextPageToken == nil) ? bootstrapTimeMin : nil

            let resp: GoogleCalendarAPI.EventsListResponse
            do {
                resp = try await apiClient.eventsList(
                    calendarID: calendar.id,
                    syncToken: syncTokenForCall,
                    bootstrapTimeMin: bootstrapTimeMinForCall,
                    pageToken: nextPageToken,
                    accessToken: accessToken
                )
            } catch GoogleCalendarAPIError.fullSyncRequired {
                // 410 — drop this calendar's cursor + tracker rows. Next
                // tick re-bootstraps. Abort page loop for this calendar.
                logger.info("calendar \(calendar.id, privacy: .public) 410 fullSyncRequired — resetting")
                try? database.writeSQL { db in
                    try GoogleCalendarSyncTokenStore.deleteEventsSyncToken(calendarId: calendar.id, in: db)
                    try GoogleCalendarTrackerStore.deleteByCalendarID(calendar.id, in: db)
                }
                return
            } catch GoogleCalendarAPIError.unauthorized {
                if retriedOn401 {
                    // Second 401 in same calendar — give up.
                    throw GoogleCalendarAPIError.unauthorized
                }
                retriedOn401 = true
                // Reactive refresh + retry from start of this calendar.
                guard let record = try readIntegrationSafely() else {
                    throw TickError.reconnectNeeded
                }
                let refreshed = try await reactiveRefresh(record: record)
                accessToken = refreshed.accessToken
                nextPageToken = nil  // restart this calendar's pagination.
                continue pageLoop
            }

            // Process this page.
            try processEventsPage(
                resp.items,
                calendar: calendar,
                userDomain: userDomain
            )

            nextPageToken = resp.nextPageToken
            if let s = resp.nextSyncToken {
                lastSyncToken = s
            }
            if nextPageToken == nil { break }
        }

        // Terminal page reached — persist nextSyncToken + clear bootstrap flag.
        if let token = lastSyncToken {
            let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
            try database.writeSQL { db in
                try GoogleCalendarSyncTokenStore.upsertEventsSyncToken(
                    calendarId: calendar.id,
                    token: token,
                    lastFullSyncAtMs: nowMs,
                    bootstrapInProgress: false,
                    nowMs: nowMs,
                    in: db
                )
            }
        }
    }

    func processEventsPage(
        _ items: [GoogleCalendarAPI.Event],
        calendar: GoogleCalendarSyncTokenStore.KnownCalendar,
        userDomain: String
    ) throws {
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)

        // Build everything first so a per-row failure doesn't half-write.
        var rawEvents: [RawEvent] = []
        var upserts: [TrackerUpsert] = []
        var deletions: [String] = []

        for event in items {
            switch classifyEvent(event, calendar: calendar, userDomain: userDomain, nowMs: nowMs) {
            case .skip:
                continue
            case .delete(let eventId):
                deletions.append(eventId)
            case .observe(let raw, let upsert):
                rawEvents.append(raw)
                if let upsert { upserts.append(upsert) }
            }
        }

        try persistProcessedPage(
            rawEvents: rawEvents, upserts: upserts, deletions: deletions, nowMs: nowMs)
    }

    /// Translate one API event into a `ProcessedEvent`. Pure (no DB writes).
    func classifyEvent(
        _ event: GoogleCalendarAPI.Event,
        calendar: GoogleCalendarSyncTokenStore.KnownCalendar,
        userDomain: String,
        nowMs: Int64
    ) -> ProcessedEvent {
        let rawType = event.eventType ?? ""
        // Blocklist BEFORE mapper — skip building payload entirely.
        if Self.eventTypeBlocklist.contains(rawType) {
            return .skip
        }
        // Cancellations: delete tracker row, do not emit observed payload
        // (Google's sync stream uses status=cancelled as a tombstone; the
        // observed-stream consumer treats absence as "row gone").
        if event.status == "cancelled", let eventId = event.id {
            return .delete(eventID: eventId)
        }
        // Build observed payload via the privacy-clipping mapper.
        guard
            let dict = GoogleCalendarEventMapper.makeObservedPayload(
                event, calendar: calendar, userDomain: userDomain
            )
        else {
            return .skip
        }
        let payload = Self.flatten(dict)
        let timestamp = Self.anchorTimestamp(payload: payload, nowMs: nowMs)
        let rawEvent = RawEvent(
            timestamp: timestamp, signalType: .context, bundleID: nil, payload: payload)
        let upsert = Self.makeTrackerUpsert(event: event, rawType: rawType, calendar: calendar)
        return .observe(rawEvent: rawEvent, upsert: upsert)
    }

    /// Tracker UPSERT for typed events. Use mapper's parser so the collector
    /// and mapper agree on time semantics.
    ///
    /// Source autoDeclineMode / chatStatus from the API Event's typed-
    /// properties blocks. Per Google contract: chatStatus exists only on
    /// focusTimeProperties (OOO has none); both hold enum buckets, never
    /// freeform user text. Persisting on the tracker lets the Task 14
    /// transition scan rebuild `_started` payloads without re-fetching the
    /// Event.
    static func makeTrackerUpsert(
        event: GoogleCalendarAPI.Event,
        rawType: String,
        calendar: GoogleCalendarSyncTokenStore.KnownCalendar
    ) -> TrackerUpsert? {
        guard
            ["focusTime", "outOfOffice", "workingLocation"].contains(rawType),
            let eventId = event.id,
            let startMs = GoogleCalendarEventMapper.parseTimePointMs(event.start),
            let endMs = GoogleCalendarEventMapper.parseTimePointMs(event.end)
        else { return nil }
        let autoDecline =
            (rawType == "focusTime")
            ? event.focusTimeProperties?.autoDeclineMode
            : ((rawType == "outOfOffice")
                ? event.outOfOfficeProperties?.autoDeclineMode
                : nil)
        let chatStatus =
            (rawType == "focusTime")
            ? event.focusTimeProperties?.chatStatus
            : nil
        return TrackerUpsert(
            eventID: eventId,
            calendarID: calendar.id,
            iCalUID: event.iCalUID,
            eventType: rawType,
            startMs: startMs,
            endMs: endMs,
            workingLocationType: event.workingLocationProperties?.type,
            autoDeclineMode: autoDecline,
            chatStatus: chatStatus
        )
    }

    /// Write events through the public Database API so FTS5 + link-derivation
    /// run consistently with every other collector. Tracker mutations land in
    /// a separate transaction — they are idempotent UPSERTs/DELETEs keyed by
    /// event id, so a crash between the two leaves at worst a stale tracker
    /// row that the next tick (or 7d cleanup) repairs.
    func persistProcessedPage(
        rawEvents: [RawEvent], upserts: [TrackerUpsert], deletions: [String], nowMs: Int64
    ) throws {
        try database.write(rawEvents)
        try database.writeSQL { db in
            for u in upserts {
                try GoogleCalendarTrackerStore.upsert(
                    GoogleCalendarTrackerStore.UpsertParams(
                        eventID: u.eventID,
                        calendarID: u.calendarID,
                        iCalUID: u.iCalUID,
                        eventType: u.eventType,
                        startMs: u.startMs,
                        endMs: u.endMs,
                        workingLocationType: u.workingLocationType,
                        autoDeclineMode: u.autoDeclineMode,
                        chatStatus: u.chatStatus,
                        upsertedAtMs: nowMs
                    ),
                    in: db
                )
            }
            for eventId in deletions {
                try GoogleCalendarTrackerStore.delete(eventID: eventId, in: db)
            }
        }
    }
}
