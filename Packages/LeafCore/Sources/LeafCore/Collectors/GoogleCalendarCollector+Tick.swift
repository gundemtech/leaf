//
//  GoogleCalendarCollector+Tick.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — `tick` orchestration + transition
//  scanner + presence_state composite write + next-meeting lookup helper.
//  Pure relocation from GoogleCalendarCollector.swift.
//

import Foundation
import GRDB

extension GoogleCalendarCollector {
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
        bumpTickCounter()

        // 4. calendarList piggy-back every N ticks (1, 13, 25, …).
        if shouldRunCalendarListSync() {
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
        let knownCalendars =
            (try? database.readSQL { db in
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
                logger.warning(
                    "calendar \(calendar.id, privacy: .public) sync failed: \(String(describing: error), privacy: .public)"
                )
            }
        }

        // 6. Tracker cleanup (7d horizon).
        let nowMs = Int64(clock().timeIntervalSince1970 * 1000)
        let cutoff = nowMs - Int64(Self.trackerRetentionSec * 1000)
        try? database.writeSQL { db in
            try GoogleCalendarTrackerStore.cleanup(beforeMs: cutoff, in: db)
        }

        // 7. Transition scan — emit `_started` / `_ended` / `_changed` event
        //    rows for tracker rows whose start_ms / end_ms boundary has been
        //    crossed since the last tick. workingLocation rows are surfaced
        //    via `rowsNeedingStartedEmit` but emitted as `.changed` (single-
        //    shot semantics — no paired `_ended`; `rowsNeedingEndedEmit`'s
        //    SQL excludes them). `markStartedEmitted` / `markEndedEmitted`
        //    flip the per-row idempotency gate so a re-tick won't duplicate.
        try? emitTransitions(nowMs: nowMs)

        // 8. Composite presence_state snapshot. Wrapped in `try?` so a
        //    transient DB error (locked WAL etc.) doesn't fail the whole
        //    tick — the next tick rebuilds the snapshot from scratch.
        //    See spec §3.3 for the field contract.
        try? writePresenceState(nowMs: nowMs)

        return true
    }

    /// Walk the tracker for time-crossings and emit the matching RawEvents.
    /// Tracker mutations (mark_emitted) run in a separate `writeSQL`
    /// transaction from the `database.write(rawEvents)` call — the same
    /// crash-safety posture as `processEventsPage`: a crash between the two
    /// leaves at worst an emitted event whose tracker flag is stale; the
    /// next tick's idempotency check would re-emit, but in practice
    /// `markStartedEmitted` is called inside the same loop iteration as
    /// the write so the window is ~one event's duration.
    func emitTransitions(nowMs: Int64) throws {
        // Started / changed scan. `rowsNeedingStartedEmit` surfaces every row
        // whose `start_ms <= now` AND `started_emitted_at_ms IS NULL`,
        // including workingLocation rows (which we re-route to `.changed`).
        let startedRows: [GoogleCalendarTrackerStore.Row] =
            (try? database.readSQL { db in
                try GoogleCalendarTrackerStore.rowsNeedingStartedEmit(now: nowMs, in: db)
            }) ?? []

        for row in startedRows {
            let phase: GoogleCalendarEventMapper.TransitionPhase =
                (row.eventType == "workingLocation") ? .changed : .started
            guard
                let payload = GoogleCalendarEventMapper.makeTransitionPayload(
                    fromTrackerRow: row, phase: phase
                )
            else { continue }
            try emitTransitionEvent(payload: payload, nowMs: nowMs)
            try database.writeSQL { db in
                try GoogleCalendarTrackerStore.markStartedEmitted(
                    eventID: row.eventID, atMs: nowMs, in: db
                )
            }
        }

        // Ended scan. Excludes workingLocation by SQL contract (single-shot).
        let endedRows: [GoogleCalendarTrackerStore.Row] =
            (try? database.readSQL { db in
                try GoogleCalendarTrackerStore.rowsNeedingEndedEmit(now: nowMs, in: db)
            }) ?? []

        for row in endedRows {
            guard
                let payload = GoogleCalendarEventMapper.makeTransitionPayload(
                    fromTrackerRow: row, phase: .ended
                )
            else { continue }
            try emitTransitionEvent(payload: payload, nowMs: nowMs)
            try database.writeSQL { db in
                try GoogleCalendarTrackerStore.markEndedEmitted(
                    eventID: row.eventID, atMs: nowMs, in: db
                )
            }
        }
    }

    /// Flatten the mapper's `[String: Any]` payload, wrap in a `RawEvent`,
    /// and write through `database.write` so FTS5 + link-derivation see the
    /// same boundary as the omnibus path.
    func emitTransitionEvent(payload: [String: Any], nowMs: Int64) throws {
        let flat = Self.flatten(payload)
        let rawEvent = RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: flat
        )
        try database.write([rawEvent])
    }

    // MARK: - presence_state composite write

    /// Composite snapshot read inside ``writePresenceState(nowMs:)`` — collected
    /// in a single `readSQL` block so the tracker-store calls share one read
    /// transaction. Promoted from an inline 5-tuple to a named struct (kept
    /// file-private; consumed only by this writer).
    struct PresenceStateSnapshot {
        let calendarCount: Int
        let focusActive: Bool
        let oooActive: Bool
        let workingLocation: String?
        let nextMeetingStartMs: Int64?
    }

    /// Build the per-tick `presence_state.google_calendar` snapshot and UPSERT
    /// it through `PresenceStateWriter`. Caller wraps in `try?` — transient
    /// DB errors should not fail the whole tick (the next tick rebuilds from
    /// scratch).
    func writePresenceState(nowMs: Int64) throws {
        let snapshot: PresenceStateSnapshot = try database.readSQL { db in
            let count = try GoogleCalendarSyncTokenStore.knownCalendars(in: db).count
            let focus = try GoogleCalendarTrackerStore.hasActiveFocusBlock(now: nowMs, in: db)
            let ooo = try GoogleCalendarTrackerStore.hasActiveOOO(now: nowMs, in: db)
            let loc = try GoogleCalendarTrackerStore.currentWorkingLocation(now: nowMs, in: db)
            let next = try Self.fetchNextMeetingStartMs(now: nowMs, in: db)
            return PresenceStateSnapshot(
                calendarCount: count,
                focusActive: focus,
                oooActive: ooo,
                workingLocation: loc,
                nextMeetingStartMs: next
            )
        }

        var state: [String: Any] = [
            "known_calendar_count": snapshot.calendarCount,
            "focus_block_active": snapshot.focusActive,
            "ooo_active": snapshot.oooActive,
            "working_location": snapshot.workingLocation as Any? ?? NSNull(),
            "next_meeting_start_ms": snapshot.nextMeetingStartMs as Any? ?? NSNull(),
            "last_synced_at_ms": nowMs,
        ]
        // Defensive: Optional<String>.none wrapped as Any survives the
        // ternary above; explicit NSNull substitution keeps JSONSerialization
        // happy regardless of Swift's Optional-to-Any bridging quirks.
        if snapshot.workingLocation == nil { state["working_location"] = NSNull() }
        if snapshot.nextMeetingStartMs == nil { state["next_meeting_start_ms"] = NSNull() }

        try database.writeSQL { db in
            try PresenceStateWriter.upsert(
                provider: .googleCalendar,
                state: state,
                derivedMode: nil,
                nowMs: nowMs,
                in: db
            )
        }
    }

    /// Earliest non-all-day `google_calendar_event_observed` whose `start_ms`
    /// is strictly in the future. Returns nil if no such event exists.
    /// RawEvent.payload values are all strings (see `flatten` above) — that's
    /// why we CAST `start_ms` to integer and compare `is_all_day` to the
    /// string `'false'`, not to `0`. The `event_kind` discriminator filter
    /// keeps this query confined to the omnibus observed-row stream
    /// (transition events live under separate `*_started` / `*_ended` kinds
    /// and carry their own `start_ms` semantics that we don't want to mix in).
    static func fetchNextMeetingStartMs(now: Int64, in db: GRDB.Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT CAST(json_extract(payload_json, '$.start_ms') AS INTEGER) AS start_ms
                  FROM events
                 WHERE json_extract(payload_json, '$.event_kind') = 'google_calendar_event_observed'
                   AND json_extract(payload_json, '$.is_all_day') = 'false'
                   AND CAST(json_extract(payload_json, '$.start_ms') AS INTEGER) > ?
                 ORDER BY start_ms ASC
                 LIMIT 1
                """,
            arguments: [now]
        )
    }
}
