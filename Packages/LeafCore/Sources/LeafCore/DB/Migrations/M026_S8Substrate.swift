import Foundation
import GRDB

/// Track 5 / S8 / T1 — adds two device-local substrates:
///
/// 1. `notification_prefs` — per-pref toggle persistence backing
///    NotificationsSettingsSection (T9 consumer). Mirrors `ShareRules`
///    normalized per-row + defaults map fallback pattern, but keyed on a
///    single `pref_kind` column (no workspace_id; preferences are device-wide).
///    Row absent → `NotificationKind.defaultEnabled` semantics apply.
///
/// 2. `messages_mirror.pending_mark_done` — ADD COLUMN flag backing the
///    APNs `dm.markDone` retry queue (T6 consumer). 1 when the optimistic
///    local UPDATE succeeded but the server PATCH failed; background retry
///    walks rows where `pending_mark_done = 1` until success.
///
/// Partial index `idx_messages_mirror_pending_mark_done` accelerates the
/// hot-path retry queue scan (WHERE `pending_mark_done = 1`).
public extension DatabaseMigrator {
    mutating func registerMigration026S8Substrate() {
        registerMigration("026_s8_substrate") { db in
            // 1. notification_prefs (mirror ShareRules normalized per-row pattern).
            try db.create(table: Schema.NotificationPrefs.tableName, ifNotExists: true) { t in
                t.column(Schema.NotificationPrefs.prefKind, .text).primaryKey().notNull()
                t.column(Schema.NotificationPrefs.enabled, .integer).notNull().defaults(to: 1)
                t.column(Schema.NotificationPrefs.updatedAtMs, .integer).notNull()
            }

            // 2. messages_mirror — ADD COLUMN pending_mark_done (T6 retry queue flag).
            try db.alter(table: Schema.MessagesMirror.tableName) { t in
                t.add(column: Schema.MessagesMirror.pendingMarkDone, .integer)
                    .notNull()
                    .defaults(to: 0)
            }

            // 3. Partial index — supports retry queue scan (WHERE pending_mark_done = 1).
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS \(Schema.MessagesMirror.indexPendingMarkDone)
                ON \(Schema.MessagesMirror.tableName)
                  (\(Schema.MessagesMirror.pendingMarkDone))
                WHERE \(Schema.MessagesMirror.pendingMarkDone) = 1
                """)
        }
    }
}
