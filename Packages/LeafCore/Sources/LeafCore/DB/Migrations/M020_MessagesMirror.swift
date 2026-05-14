import Foundation
import GRDB

/// Phase Track-5 S4 — `messages_mirror` direct-message local mirror.
///
/// PK on `message_id` (UUID lowercased, matches Supabase `direct_messages.message_id`).
/// `direction` CHECK enum constrains to 'outbound' (sender's row) or 'inbound'
/// (recipient's row). `reply_to` is logical FK to `messages_mirror.message_id` —
/// no SQL FOREIGN KEY since rejoin / multi-device race may insert child before
/// parent.
///
/// Three indexes:
/// - `idx_messages_mirror_workspace_recent` — feed list (workspace + ts DESC).
/// - `idx_messages_mirror_unread` — partial index `WHERE read_at_ms IS NULL AND direction='inbound'`.
/// - `idx_messages_mirror_open_tasks` — partial `WHERE kind='task' AND done_at_ms IS NULL`.
public extension DatabaseMigrator {
    mutating func registerMigration020MessagesMirror() {
        registerMigration("020_messages_mirror") { db in
            try db.create(table: Schema.MessagesMirror.tableName, ifNotExists: true) { t in
                t.column(Schema.MessagesMirror.messageID, .text).primaryKey().notNull()
                t.column(Schema.MessagesMirror.workspaceID, .text).notNull()
                t.column(Schema.MessagesMirror.senderPubkeyHex, .text).notNull()
                t.column(Schema.MessagesMirror.senderMemberID, .text).notNull()
                t.column(Schema.MessagesMirror.senderDisplayName, .text).notNull()
                t.column(Schema.MessagesMirror.recipientPubkeyHex, .text).notNull()
                t.column(Schema.MessagesMirror.kind, .text).notNull()
                    .check { kind in
                        kind == DirectMessageKind.handoff.rawValue
                            || kind == DirectMessageKind.task.rawValue
                            || kind == DirectMessageKind.ping.rawValue
                    }
                t.column(Schema.MessagesMirror.body, .text).notNull()
                t.column(Schema.MessagesMirror.attachmentKind, .text)
                t.column(Schema.MessagesMirror.attachmentExternalRef, .text)
                t.column(Schema.MessagesMirror.replyTo, .text)
                t.column(Schema.MessagesMirror.sentAtMs, .integer).notNull()
                t.column(Schema.MessagesMirror.serverCreatedAtMs, .integer).notNull()
                t.column(Schema.MessagesMirror.readAtMs, .integer)
                t.column(Schema.MessagesMirror.doneAtMs, .integer)
                t.column(Schema.MessagesMirror.doneByPubkeyHex, .text)
                t.column(Schema.MessagesMirror.direction, .text).notNull()
                    .check { dir in
                        dir == Schema.MessagesMirror.directionOutbound
                            || dir == Schema.MessagesMirror.directionInbound
                    }
                t.column(Schema.MessagesMirror.lastSyncedAtMs, .integer).notNull()
            }

            try db.create(
                index: Schema.MessagesMirror.indexWorkspaceRecent,
                on: Schema.MessagesMirror.tableName,
                columns: [
                    Schema.MessagesMirror.workspaceID,
                    Schema.MessagesMirror.serverCreatedAtMs
                ],
                ifNotExists: true
            )

            // Partial index — unread inbound only.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS \(Schema.MessagesMirror.indexUnread)
                ON \(Schema.MessagesMirror.tableName)
                  (\(Schema.MessagesMirror.workspaceID),
                   \(Schema.MessagesMirror.recipientPubkeyHex),
                   \(Schema.MessagesMirror.serverCreatedAtMs) DESC)
                WHERE \(Schema.MessagesMirror.readAtMs) IS NULL
                  AND \(Schema.MessagesMirror.direction) = '\(Schema.MessagesMirror.directionInbound)'
                """)

            // Partial index — open tasks only.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS \(Schema.MessagesMirror.indexOpenTasks)
                ON \(Schema.MessagesMirror.tableName)
                  (\(Schema.MessagesMirror.workspaceID),
                   \(Schema.MessagesMirror.serverCreatedAtMs) DESC)
                WHERE \(Schema.MessagesMirror.kind) = '\(DirectMessageKind.task.rawValue)'
                  AND \(Schema.MessagesMirror.doneAtMs) IS NULL
                """)
        }
    }
}
