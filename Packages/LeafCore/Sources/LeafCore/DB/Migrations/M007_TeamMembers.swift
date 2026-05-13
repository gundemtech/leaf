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
public extension DatabaseMigrator {
    mutating func registerMigration007TeamMembers() {
        // Track-5 S2: historical migration — hardcoded literals for the
        // pre-M019 column + index names (`org_id`, `team_members_org_active`).
        // M019 renames them to `workspace_id` / `team_members_workspace_active`;
        // Schema constants now resolve to the post-M019 names and must not
        // bleed forward into history.
        registerMigration("007_team_members") { db in
            try db.create(table: "team_members", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("org_id", .text).notNull()
                t.column("role", .text).notNull()
                t.column("pubkey_hex", .text).notNull()
                t.column("display_name", .text).notNull()
                t.column("added_at_ms", .integer).notNull()
                t.column("removed_at_ms", .integer)
            }

            try db.create(
                index: "team_members_org_active",
                on: "team_members",
                columns: ["org_id"],
                condition: Column("removed_at_ms") == nil
            )
        }
    }
}
