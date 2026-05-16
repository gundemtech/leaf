import Foundation
import GRDB

/// Phase Track-6 P4 Task 5 — DAO over `google_calendar_typed_event_tracker`
/// (M027). Static methods receive a raw `GRDB.Database` handle so the caller
/// wraps the operation in `pool.write`/`.read` — mirrors the
/// `IntensityAggregatesStore` / `PendingInvitesStore` shape.
///
/// **Why a dedicated tracker table, not a `events` scan?** Google Calendar
/// `focusTime` / `outOfOffice` / `workingLocation` instances cross wall-clock
/// boundaries between polling ticks. The collector needs an idempotent
/// per-event "have I already emitted `_started`/`_ended`?" gate so a re-tick
/// after the boundary doesn't double-emit. UPSERT preserves the
/// `*_emitted_at_ms` flags so server-side changes to `start_ms`/`end_ms`
/// don't reset the emission state.
///
/// **`workingLocation` exception in `rowsNeedingEndedEmit`** — working
/// location is a single-shot signal (presence ceiling: "where am I working
/// from"), so we emit only `_started`. The terminal boundary is implicit
/// (next workingLocation row covering `now` wins). The SQL explicitly
/// excludes `event_type = 'workingLocation'` from the ended-scan to avoid
/// emitting `working_location_ended` events the contract doesn't surface.
public struct GoogleCalendarTrackerStore: Sendable {

    /// Row materialized from the tracker table. `workingLocationType` is non-nil
    /// only for `eventType == "workingLocation"` rows; the bucket string is
    /// one of `"homeOffice" | "officeLocation" | "customLocation"`.
    /// `autoDeclineMode` populated for `focusTime` + `outOfOffice` rows (Google
    /// API enum bucket); `chatStatus` only for `focusTime`.
    public struct Row: Sendable, Equatable {
        public let eventID: String
        public let calendarID: String
        public let iCalUID: String?
        public let eventType: String
        public let startMs: Int64
        public let endMs: Int64
        public let startedEmittedAtMs: Int64?
        public let endedEmittedAtMs: Int64?
        public let workingLocationType: String?
        public let autoDeclineMode: String?
        public let chatStatus: String?
        public let upsertedAtMs: Int64

        public init(
            eventID: String,
            calendarID: String,
            iCalUID: String?,
            eventType: String,
            startMs: Int64,
            endMs: Int64,
            startedEmittedAtMs: Int64?,
            endedEmittedAtMs: Int64?,
            workingLocationType: String?,
            autoDeclineMode: String?,
            chatStatus: String?,
            upsertedAtMs: Int64
        ) {
            self.eventID = eventID
            self.calendarID = calendarID
            self.iCalUID = iCalUID
            self.eventType = eventType
            self.startMs = startMs
            self.endMs = endMs
            self.startedEmittedAtMs = startedEmittedAtMs
            self.endedEmittedAtMs = endedEmittedAtMs
            self.workingLocationType = workingLocationType
            self.autoDeclineMode = autoDeclineMode
            self.chatStatus = chatStatus
            self.upsertedAtMs = upsertedAtMs
        }
    }

    // MARK: - UPSERT

    /// INSERT-or-update on `event_id` PK collision. **Critical:** the
    /// `ON CONFLICT` clause deliberately does NOT touch
    /// `started_emitted_at_ms` / `ended_emitted_at_ms` — emission gating is
    /// idempotent under server-driven row refresh.
    public static func upsert(
        eventID: String,
        calendarID: String,
        iCalUID: String?,
        eventType: String,
        startMs: Int64,
        endMs: Int64,
        workingLocationType: String?,
        autoDeclineMode: String?,
        chatStatus: String?,
        upsertedAtMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.GoogleCalendarTracker.tableName) (
                    \(Schema.GoogleCalendarTracker.eventID),
                    \(Schema.GoogleCalendarTracker.calendarID),
                    \(Schema.GoogleCalendarTracker.iCalUID),
                    \(Schema.GoogleCalendarTracker.eventType),
                    \(Schema.GoogleCalendarTracker.startMs),
                    \(Schema.GoogleCalendarTracker.endMs),
                    \(Schema.GoogleCalendarTracker.workingLocationType),
                    \(Schema.GoogleCalendarTracker.autoDeclineMode),
                    \(Schema.GoogleCalendarTracker.chatStatus),
                    \(Schema.GoogleCalendarTracker.upsertedAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(\(Schema.GoogleCalendarTracker.eventID)) DO UPDATE SET
                    \(Schema.GoogleCalendarTracker.calendarID)          = excluded.\(Schema.GoogleCalendarTracker.calendarID),
                    \(Schema.GoogleCalendarTracker.iCalUID)             = excluded.\(Schema.GoogleCalendarTracker.iCalUID),
                    \(Schema.GoogleCalendarTracker.eventType)           = excluded.\(Schema.GoogleCalendarTracker.eventType),
                    \(Schema.GoogleCalendarTracker.startMs)             = excluded.\(Schema.GoogleCalendarTracker.startMs),
                    \(Schema.GoogleCalendarTracker.endMs)               = excluded.\(Schema.GoogleCalendarTracker.endMs),
                    \(Schema.GoogleCalendarTracker.workingLocationType) = excluded.\(Schema.GoogleCalendarTracker.workingLocationType),
                    \(Schema.GoogleCalendarTracker.autoDeclineMode)     = excluded.\(Schema.GoogleCalendarTracker.autoDeclineMode),
                    \(Schema.GoogleCalendarTracker.chatStatus)          = excluded.\(Schema.GoogleCalendarTracker.chatStatus),
                    \(Schema.GoogleCalendarTracker.upsertedAtMs)        = excluded.\(Schema.GoogleCalendarTracker.upsertedAtMs)
                """,
            arguments: [
                eventID, calendarID, iCalUID, eventType,
                startMs, endMs, workingLocationType,
                autoDeclineMode, chatStatus, upsertedAtMs,
            ]
        )
    }

    // MARK: - Scan queries

    /// Rows whose `start_ms` has reached `now` but whose `_started` event has
    /// not yet been emitted. Used by the collector tick to drive
    /// `focus_block_started` / `out_of_office_started` /
    /// `working_location_started` emission.
    public static func rowsNeedingStartedEmit(now: Int64, in db: GRDB.Database) throws -> [Row] {
        let rows = try GRDB.Row.fetchAll(
            db,
            sql: """
                SELECT * FROM \(Schema.GoogleCalendarTracker.tableName)
                 WHERE \(Schema.GoogleCalendarTracker.startMs) <= ?
                   AND \(Schema.GoogleCalendarTracker.startedEmittedAtMs) IS NULL
                 ORDER BY \(Schema.GoogleCalendarTracker.startMs) ASC
                """,
            arguments: [now]
        )
        return rows.map(decode)
    }

    /// Rows whose `end_ms` has reached `now`, where `_started` was previously
    /// emitted, and `_ended` has not been. Excludes `workingLocation` rows
    /// (single-shot, no terminal emission).
    public static func rowsNeedingEndedEmit(now: Int64, in db: GRDB.Database) throws -> [Row] {
        let rows = try GRDB.Row.fetchAll(
            db,
            sql: """
                SELECT * FROM \(Schema.GoogleCalendarTracker.tableName)
                 WHERE \(Schema.GoogleCalendarTracker.endMs) <= ?
                   AND \(Schema.GoogleCalendarTracker.startedEmittedAtMs) IS NOT NULL
                   AND \(Schema.GoogleCalendarTracker.endedEmittedAtMs) IS NULL
                   AND \(Schema.GoogleCalendarTracker.eventType) <> 'workingLocation'
                 ORDER BY \(Schema.GoogleCalendarTracker.endMs) ASC
                """,
            arguments: [now]
        )
        return rows.map(decode)
    }

    public static func markStartedEmitted(eventID: String, atMs: Int64, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.GoogleCalendarTracker.tableName)
                   SET \(Schema.GoogleCalendarTracker.startedEmittedAtMs) = ?
                 WHERE \(Schema.GoogleCalendarTracker.eventID) = ?
                """,
            arguments: [atMs, eventID]
        )
    }

    public static func markEndedEmitted(eventID: String, atMs: Int64, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.GoogleCalendarTracker.tableName)
                   SET \(Schema.GoogleCalendarTracker.endedEmittedAtMs) = ?
                 WHERE \(Schema.GoogleCalendarTracker.eventID) = ?
                """,
            arguments: [atMs, eventID]
        )
    }

    // MARK: - Deletion

    public static func delete(eventID: String, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                DELETE FROM \(Schema.GoogleCalendarTracker.tableName)
                 WHERE \(Schema.GoogleCalendarTracker.eventID) = ?
                """,
            arguments: [eventID]
        )
    }

    /// Used when the user unticks a calendar in Share Controls — drop every
    /// tracker row scoped to that calendar id without touching others.
    public static func deleteByCalendarID(_ calendarID: String, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                DELETE FROM \(Schema.GoogleCalendarTracker.tableName)
                 WHERE \(Schema.GoogleCalendarTracker.calendarID) = ?
                """,
            arguments: [calendarID]
        )
    }

    /// Drop rows whose `end_ms` is strictly before `beforeMs`. Boundary is
    /// non-inclusive so a row whose end exactly equals the cutoff is kept
    /// (still queryable from the presence-state path on the same tick).
    public static func cleanup(beforeMs: Int64, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                DELETE FROM \(Schema.GoogleCalendarTracker.tableName)
                 WHERE \(Schema.GoogleCalendarTracker.endMs) < ?
                """,
            arguments: [beforeMs]
        )
    }

    // MARK: - Presence-state queries

    public static func hasActiveFocusBlock(now: Int64, in db: GRDB.Database) throws -> Bool {
        try hasActive(eventType: "focusTime", now: now, in: db)
    }

    public static func hasActiveOOO(now: Int64, in db: GRDB.Database) throws -> Bool {
        try hasActive(eventType: "outOfOffice", now: now, in: db)
    }

    /// Returns the `workingLocationType` bucket string of the most recently
    /// started `workingLocation` row that covers `now` (`start_ms <= now < end_ms`).
    /// Returns nil if no working-location row is currently active.
    public static func currentWorkingLocation(now: Int64, in db: GRDB.Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
                SELECT \(Schema.GoogleCalendarTracker.workingLocationType)
                  FROM \(Schema.GoogleCalendarTracker.tableName)
                 WHERE \(Schema.GoogleCalendarTracker.eventType) = 'workingLocation'
                   AND \(Schema.GoogleCalendarTracker.startMs) <= ?
                   AND \(Schema.GoogleCalendarTracker.endMs) > ?
                 ORDER BY \(Schema.GoogleCalendarTracker.startMs) DESC
                 LIMIT 1
                """,
            arguments: [now, now]
        )
    }

    // MARK: - Private helpers

    private static func hasActive(eventType: String, now: Int64, in db: GRDB.Database) throws -> Bool {
        let n = try Int.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM \(Schema.GoogleCalendarTracker.tableName)
                     WHERE \(Schema.GoogleCalendarTracker.eventType) = ?
                       AND \(Schema.GoogleCalendarTracker.startMs) <= ?
                       AND \(Schema.GoogleCalendarTracker.endMs) > ?
                )
                """,
            arguments: [eventType, now, now]
        )
        return (n ?? 0) != 0
    }

    private static func decode(_ row: GRDB.Row) -> Row {
        Row(
            eventID: row[Schema.GoogleCalendarTracker.eventID],
            calendarID: row[Schema.GoogleCalendarTracker.calendarID],
            iCalUID: row[Schema.GoogleCalendarTracker.iCalUID],
            eventType: row[Schema.GoogleCalendarTracker.eventType],
            startMs: row[Schema.GoogleCalendarTracker.startMs],
            endMs: row[Schema.GoogleCalendarTracker.endMs],
            startedEmittedAtMs: row[Schema.GoogleCalendarTracker.startedEmittedAtMs],
            endedEmittedAtMs: row[Schema.GoogleCalendarTracker.endedEmittedAtMs],
            workingLocationType: row[Schema.GoogleCalendarTracker.workingLocationType],
            autoDeclineMode: row[Schema.GoogleCalendarTracker.autoDeclineMode],
            chatStatus: row[Schema.GoogleCalendarTracker.chatStatus],
            upsertedAtMs: row[Schema.GoogleCalendarTracker.upsertedAtMs]
        )
    }
}
