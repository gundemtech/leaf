import Foundation
import GRDB

/// Phase Track-5 S5 — `team_events_mirror` auto-shared events local mirror
/// (recipient side). Composite PK `(workspace_id, event_id)` allows the same
/// event_id across workspaces (theoretical multi-workspace case). Retention
/// (90d default) enforced by `TeamEventMirrorRetentionPruner`, not the schema.
///
/// `plaintext_payload_json` stores the ADR-010-filtered subset of
/// `TeamEventPayload.fields` (already passed through allowlist + truncation in
/// `TeamEventPayloadBuilder`). Banned keys (body / file_contents / note_body /
/// email_subject / preview / prompt / response / *_message_text) NEVER land
/// here by construction.
///
/// Two indexes:
/// - `idx_team_events_mirror_workspace_created` — feed list (workspace + ts DESC)
/// - `idx_team_events_mirror_sender` — per-teammate filter (workspace + sender + ts DESC)
public extension DatabaseMigrator {
    mutating func registerMigration023TeamEventsMirror() {
        registerMigration("023_team_events_mirror") { db in
            try db.create(table: Schema.TeamEventsMirror.tableName, ifNotExists: true) { t in
                t.column(Schema.TeamEventsMirror.eventID, .text).notNull()
                t.column(Schema.TeamEventsMirror.workspaceID, .text).notNull()
                t.column(Schema.TeamEventsMirror.senderPubkeyHex, .text).notNull()
                t.column(Schema.TeamEventsMirror.sourceKind, .text).notNull()
                t.column(Schema.TeamEventsMirror.kind, .text).notNull()
                t.column(Schema.TeamEventsMirror.plaintextPayloadJSON, .text).notNull()
                t.column(Schema.TeamEventsMirror.serverCreatedAtMs, .integer).notNull()
                t.column(Schema.TeamEventsMirror.eventTsMs, .integer).notNull()
                t.column(Schema.TeamEventsMirror.receivedAtMs, .integer).notNull()
                t.primaryKey([
                    Schema.TeamEventsMirror.workspaceID,
                    Schema.TeamEventsMirror.eventID
                ])
            }

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS \(Schema.TeamEventsMirror.indexWorkspaceCreated)
                ON \(Schema.TeamEventsMirror.tableName)
                  (\(Schema.TeamEventsMirror.workspaceID),
                   \(Schema.TeamEventsMirror.serverCreatedAtMs) DESC)
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS \(Schema.TeamEventsMirror.indexSender)
                ON \(Schema.TeamEventsMirror.tableName)
                  (\(Schema.TeamEventsMirror.workspaceID),
                   \(Schema.TeamEventsMirror.senderPubkeyHex),
                   \(Schema.TeamEventsMirror.serverCreatedAtMs) DESC)
                """)
        }
    }
}
