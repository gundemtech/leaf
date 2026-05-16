//
//  GoogleCalendarCollector.swift
//  LeafCore
//
//  Track-6 P4 Task 13 — Google Calendar v3 polling collector.
//  Bootstrap + steady-state events.list sync per spec §8.2.
//  No transitions yet (Task 14), no presence_state writes (Task 16).
//
//  Tick flow:
//    1. Read IntegrationRecord (skip silently if absent).
//    2. Proactive token refresh; .invalidGrant → .reconnectNeeded.
//    3. Every Nth tick (default 12 = ~1h on 5m cadence) + first tick after
//       connect: calendarList sync (walk pages on initial fetch, diff vs
//       knownCalendars, prune deletions).
//    4. Per known calendar: pull events.list pages until terminal
//       (nextPageToken == nil). On terminal page persist nextSyncToken +
//       clear bootstrapInProgress. On 410 → drop calendar token + tracker
//       rows, retry next tick. On 401 → reactive refresh + retry once.
//    5. Emit one `google_calendar_event_observed` row per non-blocklisted
//       event. UPSERT tracker for focusTime/outOfOffice/workingLocation;
//       DELETE tracker on status="cancelled".
//    6. Cleanup tracker rows older than 7d.
//
//  ADR-010 boundary: payloads built by `GoogleCalendarEventMapper` (which
//  drops description/location/attendee PII/declineMessage etc). The
//  collector only converts the mapper's Any-typed dict into the
//  RawEvent string-string payload shape — no body fields leak through here.
//

import Foundation
import os

/// Track-6 P4 Task 13 — Google Calendar polling collector.
///
/// Mirrors LinearCollector at the high level (read integration → refresh →
/// fetch → emit events → persist cursor) but uses per-calendar syncToken
/// cursors in `provider_snapshots` rather than the `collector_offsets` row
/// pattern (Google's sync semantics is per-calendar, not a single global
/// updatedAt watermark).
public actor GoogleCalendarCollector {

    /// Bundle IDs Google emits that we do not want to surface as work events.
    /// `fromGmail` = auto-extracted bookings from email; `birthday` = the
    /// virtual Contacts birthdays calendar entries. Filter applies BEFORE
    /// mapper to avoid building/discarding payloads downstream.
    public static let eventTypeBlocklist: Set<String> = ["fromGmail", "birthday"]

    /// Bootstrap window — how far back the first sweep reaches. 365 days
    /// gives Derived Insights enough history to compute month-over-month
    /// without dragging in distant low-value past entries.
    private static let bootstrapWindowSec: TimeInterval = 365 * 24 * 3600

    /// Tracker cleanup horizon. Rows whose `end_ms` is older than this are
    /// dropped on every tick — they can no longer drive any "currently
    /// active" presence-state query.
    private static let trackerRetentionSec: TimeInterval = 7 * 24 * 3600

    /// AccessRole values we treat as a "real" calendar to sync. `freeBusyReader`
    /// is excluded — no event bodies/metadata available there anyway.
    private static let syncableAccessRoles: Set<String> = ["owner", "writer", "reader"]

    public enum TickError: Error, Sendable {
        /// Refresh token rejected with `invalid_grant` (revoked / 7-day testing
        /// expiry / scope change). Caller transitions ConnectionState to
        /// `.reconnectNeeded` per spec §7.5.
        case reconnectNeeded
    }

    private let apiClient: GoogleCalendarAPIClient
    private let tokenRefresher: GoogleCalendarTokenRefresher
    private let database: Database
    private let clock: @Sendable () -> Date
    private let pollIntervalSec: TimeInterval
    private let calendarListEveryNTicks: Int
    private let logger: Logger

    private var tickCounter: Int = 0
    private var loopTask: Task<Void, Never>?

    public init(
        apiClient: GoogleCalendarAPIClient,
        tokenRefresher: GoogleCalendarTokenRefresher,
        database: Database,
        clock: @escaping @Sendable () -> Date = { Date() },
        pollIntervalSec: TimeInterval = 300,
        calendarListEveryNTicks: Int = 12,
        logger: Logger = Logger(subsystem: "tech.gundem.leaf", category: "google-calendar-collector")
    ) {
        self.apiClient = apiClient
        self.tokenRefresher = tokenRefresher
        self.database = database
        self.clock = clock
        self.pollIntervalSec = pollIntervalSec
        self.calendarListEveryNTicks = calendarListEveryNTicks
        self.logger = logger
    }

    // MARK: - Public API

    /// Run one full tick. Returns false if the integration is absent (silent
    /// skip — collector not connected) or if the entire tick was a no-op
    /// because Google rate-limited every per-calendar call. Throws only on
    /// fatal `.reconnectNeeded`; transient errors are logged + swallowed so
    /// the next tick retries without bubbling up to Agent's runloop.
    @discardableResult
    public func tick() async throws -> Bool {
        // 1. Read integration row.
        guard let initialRecord = try readIntegrationSafely() else {
            return false
        }

        // 2. Proactive refresh.
        let activeRecord: IntegrationRecord
        do {
            activeRecord = try await proactiveRefresh(record: initialRecord)
        } catch TickError.reconnectNeeded {
            throw TickError.reconnectNeeded
        }

        // 3. Tick counter — flips first-tick gate.
        tickCounter += 1

        // 4. calendarList piggy-back every N ticks (1, 13, 25, …).
        if tickCounter % calendarListEveryNTicks == 1 {
            do {
                try await syncCalendarList(accessToken: activeRecord.accessToken)
            } catch GoogleCalendarAPIError.unauthorized {
                // 401 on calendarList — reactive refresh + retry once. If
                // the retry itself fails, log + continue (events.list will
                // hit the same 401 and surface .reconnectNeeded then).
                if let refreshed = try? await reactiveRefresh(record: activeRecord) {
                    try? await syncCalendarList(accessToken: refreshed.accessToken)
                }
            } catch {
                logger.error("calendarList sync failed: \(String(describing: error), privacy: .public)")
            }
        }

        // 5. Per-calendar events.list sync.
        let userDomain = Self.extractDomain(from: activeRecord.workspaceID) ?? ""
        let knownCalendars = (try? database.readSQL { db in
            try GoogleCalendarSyncTokenStore.knownCalendars(in: db)
        }) ?? []

        var workingToken = activeRecord.accessToken
        for calendar in knownCalendars {
            do {
                try await syncCalendarEvents(
                    calendar: calendar,
                    accessToken: &workingToken,
                    userDomain: userDomain
                )
            } catch TickError.reconnectNeeded {
                throw TickError.reconnectNeeded
            } catch GoogleCalendarAPIError.notFound {
                // Calendar gone (user unsubscribed mid-tick). Drop per-cal
                // cursor + tracker rows; next calendarList sweep will prune
                // it from `known_calendars`.
                logger.info("calendar \(calendar.id, privacy: .public) returns 404 — dropping cursor")
                try? database.writeSQL { db in
                    try GoogleCalendarSyncTokenStore.deleteEventsSyncToken(calendarId: calendar.id, in: db)
                    try GoogleCalendarTrackerStore.deleteByCalendarID(calendar.id, in: db)
                }
            } catch {
                // Transient — log and continue with next calendar. Cursor
                // not advanced for this calendar, so next tick retries.
                logger.warning("calendar \(calendar.id, privacy: .public) sync failed: \(String(describing: error), privacy: .public)")
            }
        }

        // 6. Tracker cleanup (7d horizon).
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
        let cutoff = nowMs - Int64(Self.trackerRetentionSec * 1000)
        try? database.writeSQL { db in
            try GoogleCalendarTrackerStore.cleanup(beforeMs: cutoff, in: db)
        }

        return true
    }

    /// Long-running loop. Cancel via the returned Task or by calling `stop()`.
    public func start() async {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        logger.info("GoogleCalendarCollector started (interval=\(self.pollIntervalSec, privacy: .public)s)")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
    }

    private func runLoop() async {
        await sleep(seconds: min(pollIntervalSec, 5))
        while !Task.isCancelled {
            do {
                _ = try await tick()
            } catch TickError.reconnectNeeded {
                logger.warning("tick aborted — reconnect needed; will retry next tick")
            } catch {
                logger.error("tick failed: \(String(describing: error), privacy: .public)")
            }
            await sleep(seconds: pollIntervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    // MARK: - Refresh helpers

    private func readIntegrationSafely() throws -> IntegrationRecord? {
        do {
            return try database.readIntegration(provider: .googleCalendar)
        } catch {
            logger.error("readIntegration failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Run a proactive refresh and persist the new token if Google rotated it.
    /// `.invalidGrant` propagates as `.reconnectNeeded`. Returns the
    /// IntegrationRecord that callers should use for the rest of this tick
    /// (either unchanged on `.notDue`, or rebuilt on `.refreshed`).
    private func proactiveRefresh(record: IntegrationRecord) async throws -> IntegrationRecord {
        guard let refreshToken = record.refreshToken else {
            // Long-lived assumption — Google docs say refresh_token always
            // returned on first consent; missing here means data corruption
            // or pre-refresh-storage legacy state. Skip refresh, let any
            // 401 fall through to reactive path.
            return record
        }
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
        let outcome = try await tokenRefresher.refreshIfDueProactive(
            currentAccessToken: record.accessToken,
            currentRefreshToken: refreshToken,
            currentExpiresAtMs: record.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            nowMs: nowMs
        )
        switch outcome {
        case .notDue:
            return record
        case .refreshed(let accessToken, let expiresAtMs, let rotatedRefreshToken):
            return try persistRefreshed(
                record: record,
                accessToken: accessToken,
                expiresAtMs: expiresAtMs,
                rotatedRefreshToken: rotatedRefreshToken
            )
        case .invalidGrant:
            throw TickError.reconnectNeeded
        }
    }

    /// Reactive refresh after a 401. Same outcome shape as proactive minus
    /// `.notDue`. Returns the rebuilt record on success, nil on `.invalidGrant`
    /// (which transitions tick to .reconnectNeeded via re-throw).
    private func reactiveRefresh(record: IntegrationRecord) async throws -> IntegrationRecord {
        guard let refreshToken = record.refreshToken else {
            throw TickError.reconnectNeeded
        }
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
        let outcome = try await tokenRefresher.refreshOn401(
            currentRefreshToken: refreshToken,
            nowMs: nowMs
        )
        switch outcome {
        case .refreshed(let accessToken, let expiresAtMs, let rotatedRefreshToken):
            return try persistRefreshed(
                record: record,
                accessToken: accessToken,
                expiresAtMs: expiresAtMs,
                rotatedRefreshToken: rotatedRefreshToken
            )
        case .invalidGrant:
            throw TickError.reconnectNeeded
        case .notDue:
            // Refresher should never return `.notDue` from refreshOn401 —
            // defensive fall-through. Return the original record.
            return record
        }
    }

    private func persistRefreshed(
        record: IntegrationRecord,
        accessToken: String,
        expiresAtMs: Int64,
        rotatedRefreshToken: String?
    ) throws -> IntegrationRecord {
        let now = clock()
        let updated = IntegrationRecord(
            provider: record.provider,
            workspaceID: record.workspaceID,
            workspaceName: record.workspaceName,
            accessToken: accessToken,
            // Google MAY omit refresh_token on rotation — preserve previous.
            refreshToken: rotatedRefreshToken ?? record.refreshToken,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000.0),
            scope: record.scope,
            connectedAt: record.connectedAt,
            updatedAt: now
        )
        try database.upsertIntegration(updated)
        return updated
    }

    // MARK: - calendarList sync

    /// Walk calendarList pages (initial: no syncToken → walk all pages; delta:
    /// just the first page since Google never paginates delta responses to
    /// any practical degree), then diff vs `known_calendars` and prune.
    private func syncCalendarList(accessToken: String) async throws {
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
        let newKnown = allItems
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
        let oldKnown = (try? database.readSQL { db in
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

    private func syncCalendarEvents(
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
        let bootstrapTimeMin: Date? = bootstrap
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
                nextPageToken = nil   // restart this calendar's pagination.
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

    /// Build RawEvent rows + UPSERT tracker for typed events on a single
    /// events.list page. Atomic per event (separate writes so a single
    /// malformed payload doesn't abort the whole page).
    private func processEventsPage(
        _ items: [GoogleCalendarAPI.Event],
        calendar: GoogleCalendarSyncTokenStore.KnownCalendar,
        userDomain: String
    ) throws {
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)

        // Build everything first so a per-row failure doesn't half-write.
        var rawEvents: [RawEvent] = []
        struct TrackerUpsert {
            let eventID: String
            let calendarID: String
            let iCalUID: String?
            let eventType: String
            let startMs: Int64
            let endMs: Int64
            let workingLocationType: String?
        }
        var upserts: [TrackerUpsert] = []
        var deletions: [String] = []

        for event in items {
            let rawType = event.eventType ?? ""
            // Blocklist BEFORE mapper — skip building payload entirely.
            if Self.eventTypeBlocklist.contains(rawType) {
                continue
            }

            // Cancellations: delete tracker row, do not emit observed payload
            // (Google's sync stream uses status=cancelled as a tombstone; the
            // observed-stream consumer treats absence as "row gone").
            if event.status == "cancelled", let eventId = event.id {
                deletions.append(eventId)
                continue
            }

            // Build observed payload via the privacy-clipping mapper.
            guard let dict = GoogleCalendarEventMapper.makeObservedPayload(
                event, calendar: calendar, userDomain: userDomain
            ) else {
                continue
            }
            let payload = Self.flatten(dict)

            // Timestamp anchor: prefer event.updated, fall back to start_ms,
            // fall back to tick time. Stable timestamps matter for the
            // chronological events index.
            let timestamp: Date = {
                if let updated = payload["updated_ms"], let ms = Int64(updated) {
                    return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
                }
                if let start = payload["start_ms"], let ms = Int64(start) {
                    return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
                }
                return Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0)
            }()

            rawEvents.append(RawEvent(
                timestamp: timestamp,
                signalType: .context,
                bundleID: nil,
                payload: payload
            ))

            // Tracker UPSERT for typed events. Use mapper's parser so the
            // collector and mapper agree on time semantics.
            if ["focusTime", "outOfOffice", "workingLocation"].contains(rawType),
               let eventId = event.id,
               let startMs = GoogleCalendarEventMapper.parseTimePointMs(event.start),
               let endMs = GoogleCalendarEventMapper.parseTimePointMs(event.end) {
                upserts.append(TrackerUpsert(
                    eventID: eventId,
                    calendarID: calendar.id,
                    iCalUID: event.iCalUID,
                    eventType: rawType,
                    startMs: startMs,
                    endMs: endMs,
                    workingLocationType: event.workingLocationProperties?.type
                ))
            }
        }

        // Write events through the public Database API so FTS5 + link-derivation
        // run consistently with every other collector. Tracker mutations land in
        // a separate transaction — they are idempotent UPSERTs/DELETEs keyed by
        // event id, so a crash between the two leaves at worst a stale tracker
        // row that the next tick (or 7d cleanup) repairs.
        try database.write(rawEvents)

        try database.writeSQL { db in
            for u in upserts {
                try GoogleCalendarTrackerStore.upsert(
                    eventID: u.eventID,
                    calendarID: u.calendarID,
                    iCalUID: u.iCalUID,
                    eventType: u.eventType,
                    startMs: u.startMs,
                    endMs: u.endMs,
                    workingLocationType: u.workingLocationType,
                    upsertedAtMs: nowMs,
                    in: db
                )
            }
            for eventId in deletions {
                try GoogleCalendarTrackerStore.delete(eventID: eventId, in: db)
            }
        }
    }

    // MARK: - Helpers

    /// Extract domain part from an email-shaped string. Returns nil if no
    /// `@` is present (e.g. integration `workspaceID` is not an email yet —
    /// edge case for legacy bootstraps).
    static func extractDomain(from email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        return String(email[email.index(after: at)...])
    }

    /// Flatten the mapper's `[String: Any]` dict into `[String: String]` for
    /// `RawEvent.payload`. Bool → "true"/"false" (matches Linear collector
    /// convention for `body_truncated` etc.). Int64/Int/Double → decimal
    /// string. Everything else → `String(describing:)`. Privacy: this layer
    /// never injects keys — it only converts whatever the mapper produced.
    static func flatten(_ dict: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(dict.count)
        for (key, value) in dict {
            switch value {
            case let s as String:
                out[key] = s
            case let b as Bool:
                out[key] = b ? "true" : "false"
            case let i as Int64:
                out[key] = String(i)
            case let i as Int:
                out[key] = String(i)
            case let d as Double:
                out[key] = String(d)
            default:
                out[key] = String(describing: value)
            }
        }
        return out
    }
}
