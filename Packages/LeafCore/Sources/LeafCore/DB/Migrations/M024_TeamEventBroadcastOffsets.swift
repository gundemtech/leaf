import Foundation
import GRDB

/// Phase Track-5 S5 — per-workspace cursor for `TeamEventBroadcastService`.
/// One row per workspace; PK on `workspace_id`. `cursor_event_id` advances
/// monotonically over local `events.id` integers (matches `DetectorOffsets`
/// pattern). `consecutive_failures` tracks exponential backoff
/// (cap 30s × 2^min(failures, 6) = 32min max — enforced in service tick).
public extension DatabaseMigrator {
    mutating func registerMigration024TeamEventBroadcastOffsets() {
        registerMigration("024_team_event_broadcast_offsets") { db in
            try db.create(table: Schema.TeamEventBroadcastOffsets.tableName, ifNotExists: true) { t in
                t.column(Schema.TeamEventBroadcastOffsets.workspaceID, .text).primaryKey().notNull()
                t.column(Schema.TeamEventBroadcastOffsets.cursorEventID, .integer).notNull().defaults(to: 0)
                t.column(Schema.TeamEventBroadcastOffsets.lastAttemptAtMs, .integer)
                t.column(Schema.TeamEventBroadcastOffsets.lastSuccessAtMs, .integer)
                t.column(Schema.TeamEventBroadcastOffsets.consecutiveFailures, .integer).notNull().defaults(to: 0)
            }
        }
    }
}
