import Foundation
import GRDB

/// Phase Track-5 S5 — CRUD over `team_event_broadcast_offsets`. One row per
/// workspace. Cursor advances monotonically over local `events.id` integers
/// (matches `DetectorOffsets` pattern); failure/success counters drive
/// exponential backoff in `TeamEventBroadcastService`.
public struct TeamEventBroadcastOffsetsStore: Sendable {

    /// Read cursor. Returns a row with defaults if absent (cursor_event_id=0,
    /// consecutive_failures=0, nullable timestamps) — caller observes the
    /// distinction via `row.lastAttemptAtMs == nil`.
    public static func readOrDefault(
        workspaceID: String,
        in db: GRDB.Database
    ) throws -> TeamEventBroadcastOffset {
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT \(Schema.TeamEventBroadcastOffsets.workspaceID),
                       \(Schema.TeamEventBroadcastOffsets.cursorEventID),
                       \(Schema.TeamEventBroadcastOffsets.lastAttemptAtMs),
                       \(Schema.TeamEventBroadcastOffsets.lastSuccessAtMs),
                       \(Schema.TeamEventBroadcastOffsets.consecutiveFailures)
                FROM \(Schema.TeamEventBroadcastOffsets.tableName)
                WHERE \(Schema.TeamEventBroadcastOffsets.workspaceID) = ?
                LIMIT 1
                """,
            arguments: [workspaceID]
        ),
        let wsID = row[Schema.TeamEventBroadcastOffsets.workspaceID] as String?,
        let cursor = row[Schema.TeamEventBroadcastOffsets.cursorEventID] as Int64?,
        let fails = row[Schema.TeamEventBroadcastOffsets.consecutiveFailures] as Int? {
            return TeamEventBroadcastOffset(
                workspaceID: wsID,
                cursorEventID: cursor,
                lastAttemptAtMs: row[Schema.TeamEventBroadcastOffsets.lastAttemptAtMs] as Int64?,
                lastSuccessAtMs: row[Schema.TeamEventBroadcastOffsets.lastSuccessAtMs] as Int64?,
                consecutiveFailures: fails
            )
        }
        return TeamEventBroadcastOffset(
            workspaceID: workspaceID,
            cursorEventID: 0,
            lastAttemptAtMs: nil,
            lastSuccessAtMs: nil,
            consecutiveFailures: 0
        )
    }

    /// Advance cursor to `toEventID`. Resets `consecutive_failures` to 0
    /// implicitly via `recordSuccess`. UPSERTs row if absent.
    public static func advanceCursor(
        workspaceID: String,
        toEventID: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.TeamEventBroadcastOffsets.tableName) (
                    \(Schema.TeamEventBroadcastOffsets.workspaceID),
                    \(Schema.TeamEventBroadcastOffsets.cursorEventID)
                ) VALUES (?, ?)
                ON CONFLICT(\(Schema.TeamEventBroadcastOffsets.workspaceID))
                DO UPDATE SET
                    \(Schema.TeamEventBroadcastOffsets.cursorEventID) = excluded.\(Schema.TeamEventBroadcastOffsets.cursorEventID)
                """,
            arguments: [workspaceID, toEventID]
        )
    }

    /// Record a successful tick: sets last_success_at_ms, last_attempt_at_ms,
    /// resets consecutive_failures = 0. UPSERTs row if absent.
    public static func recordSuccess(
        workspaceID: String,
        nowMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.TeamEventBroadcastOffsets.tableName) (
                    \(Schema.TeamEventBroadcastOffsets.workspaceID),
                    \(Schema.TeamEventBroadcastOffsets.lastAttemptAtMs),
                    \(Schema.TeamEventBroadcastOffsets.lastSuccessAtMs),
                    \(Schema.TeamEventBroadcastOffsets.consecutiveFailures)
                ) VALUES (?, ?, ?, 0)
                ON CONFLICT(\(Schema.TeamEventBroadcastOffsets.workspaceID))
                DO UPDATE SET
                    \(Schema.TeamEventBroadcastOffsets.lastAttemptAtMs)     = excluded.\(Schema.TeamEventBroadcastOffsets.lastAttemptAtMs),
                    \(Schema.TeamEventBroadcastOffsets.lastSuccessAtMs)     = excluded.\(Schema.TeamEventBroadcastOffsets.lastSuccessAtMs),
                    \(Schema.TeamEventBroadcastOffsets.consecutiveFailures) = 0
                """,
            arguments: [workspaceID, nowMs, nowMs]
        )
    }

    /// Record a failed tick: sets last_attempt_at_ms, increments
    /// consecutive_failures. UPSERTs row if absent.
    public static func recordFailure(
        workspaceID: String,
        nowMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.TeamEventBroadcastOffsets.tableName) (
                    \(Schema.TeamEventBroadcastOffsets.workspaceID),
                    \(Schema.TeamEventBroadcastOffsets.lastAttemptAtMs),
                    \(Schema.TeamEventBroadcastOffsets.consecutiveFailures)
                ) VALUES (?, ?, 1)
                ON CONFLICT(\(Schema.TeamEventBroadcastOffsets.workspaceID))
                DO UPDATE SET
                    \(Schema.TeamEventBroadcastOffsets.lastAttemptAtMs)     = excluded.\(Schema.TeamEventBroadcastOffsets.lastAttemptAtMs),
                    \(Schema.TeamEventBroadcastOffsets.consecutiveFailures) = \(Schema.TeamEventBroadcastOffsets.tableName).\(Schema.TeamEventBroadcastOffsets.consecutiveFailures) + 1
                """,
            arguments: [workspaceID, nowMs]
        )
    }
}
