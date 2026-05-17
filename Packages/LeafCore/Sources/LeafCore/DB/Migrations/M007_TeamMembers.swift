import Foundation
import GRDB

/// Phase 5.1.A — `team_members` long-term member identity + X25519 pubkey
/// (Phase 5 architecture contract §4 Identity, §7 Key lifecycle).
/// Schema публична (whitepaper storage.md). SQL DDL — не moat.
///
/// `org_id` — logical FK на `org.id`; `removed_at_ms` IS NULL = active member
/// (устанавливается в Phase 5.3 на removal).
/// `role` — `TeamMemberRole.rawValue` ('admin' | 'member'); validated в Swift,
/// без CHECK constraint (см. spec 5.1.A §4).
/// `pubkey_hex` — X25519 32-byte public, hex-encoded (64 chars).
///
/// Partial index `team_members_org_active` — под frequent query
/// "active members этой org" в Team UI.
extension DatabaseMigrator {
    public mutating func registerMigration007TeamMembers() {
        registerMigration("007_team_members") { db in
            try db.create(table: Schema.TeamMembers.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.TeamMembers.id, .text)
                t.column(Schema.TeamMembers.orgID, .text).notNull()
                t.column(Schema.TeamMembers.role, .text).notNull()
                t.column(Schema.TeamMembers.pubkeyHex, .text).notNull()
                t.column(Schema.TeamMembers.displayName, .text).notNull()
                t.column(Schema.TeamMembers.addedAtMs, .integer).notNull()
                t.column(Schema.TeamMembers.removedAtMs, .integer)
            }

            try db.create(
                index: Schema.TeamMembers.indexOrgActive,
                on: Schema.TeamMembers.tableName,
                columns: [Schema.TeamMembers.orgID],
                condition: Column(Schema.TeamMembers.removedAtMs) == nil
            )
        }
    }
}
