import Foundation
import GRDB

/// Phase Track-5 S2 — single-org → multi-workspace substrate migration.
/// Renames `org` table → `workspaces`; renames `team_members.org_id` →
/// `workspace_id`; adds `workspace_id` FK + backfill to team_keys /
/// rotation_outbox / pending_invites; adds `workspaces.left_at_ms`
/// (OQ-T5-2 soft-mark); drops + recreates active-members index with new
/// column name.
///
/// **Atomic** — GRDB wraps migration body in implicit tx; partial application
/// rolls back. Forward-only per repo convention (no `down` SQL).
///
/// **Legacy keystore relocation** — also calls
/// `TeamKeystore.relocateLegacyTeamKeys(toWorkspaceID:)` for the existing
/// single workspace's UUID, moving `<root>/team-keys/<id>.key` →
/// `<root>/workspaces/<workspace-uuid>/team-keys/<id>.key`. Idempotent.
/// Best-effort: filesystem errors NOT throw — DB migration must succeed
/// even if keystore relocation fails (teamKey can be re-fetched from relay).
///
/// **SQLite quirk**: `ALTER TABLE ADD COLUMN ... DEFAULT ?` does NOT support
/// parameter binding for the DEFAULT clause. The backfill UUID is
/// interpolated into the SQL string. Safe: UUIDs contain no quote chars;
/// the only other possible value is `""` empty sentinel for fresh-DB path.
public extension DatabaseMigrator {
    mutating func registerMigration019Workspaces() {
        registerMigration("019_workspaces") { db in
            // Step 1 — rename `org` table → `workspaces`.
            try db.execute(sql: "ALTER TABLE org RENAME TO workspaces")

            // Step 2 — add `workspaces.left_at_ms` (nullable; NULL = active).
            try db.alter(table: Schema.Workspaces.tableName) { t in
                t.add(column: Schema.Workspaces.leftAtMs, .integer)
            }

            // Step 3 — rename `team_members.org_id` → `workspace_id`.
            // SQLite 3.25+ ALTER RENAME COLUMN auto-updates index definitions
            // that reference the column.
            try db.execute(sql: """
                ALTER TABLE \(Schema.TeamMembers.tableName)
                RENAME COLUMN org_id TO \(Schema.TeamMembers.workspaceID)
                """)

            // Step 4 — pre-fetch first workspace's id for ADD COLUMN backfill.
            // On fresh DB (no existing org row), firstWorkspaceID = nil →
            // sentinel "" used. Sentinel never matches real-workspace queries;
            // child rows backfilled to "" remain orphan-equivalent for queries
            // requiring a real workspace_id. Practical: fresh DB has no child
            // rows yet, so ADD COLUMN's DEFAULT fires zero times.
            let firstWorkspaceID: String? = try String.fetchOne(db, sql: """
                SELECT \(Schema.Workspaces.id)
                FROM \(Schema.Workspaces.tableName)
                ORDER BY \(Schema.Workspaces.createdAtMs) ASC
                LIMIT 1
                """)
            let backfill = firstWorkspaceID ?? ""

            // Step 5 — add `team_keys.workspace_id` with backfill.
            try db.execute(sql: """
                ALTER TABLE \(Schema.TeamKeys.tableName)
                ADD COLUMN \(Schema.TeamKeys.workspaceID) TEXT NOT NULL DEFAULT '\(backfill)'
                """)

            // Step 6 — `rotation_outbox.workspace_id`.
            try db.execute(sql: """
                ALTER TABLE \(Schema.RotationOutbox.tableName)
                ADD COLUMN \(Schema.RotationOutbox.workspaceID) TEXT NOT NULL DEFAULT '\(backfill)'
                """)

            // Step 7 — `pending_invites.workspace_id`.
            try db.execute(sql: """
                ALTER TABLE \(Schema.PendingInvites.tableName)
                ADD COLUMN \(Schema.PendingInvites.workspaceID) TEXT NOT NULL DEFAULT '\(backfill)'
                """)

            // Step 8 — drop old index, create new with renamed column.
            // SQLite 3.25+ auto-updates referenced column inside index defs on
            // RENAME COLUMN, but the index NAME does not auto-update; we drop +
            // recreate explicitly for clarity (and to match Schema constant).
            try db.execute(sql: "DROP INDEX IF EXISTS team_members_org_active")
            try db.create(
                index: Schema.TeamMembers.indexWorkspaceActive,
                on: Schema.TeamMembers.tableName,
                columns: [Schema.TeamMembers.workspaceID],
                condition: Column(Schema.TeamMembers.removedAtMs) == nil
            )

            // Step 9 — best-effort legacy keystore relocation.
            // Only runs if there was an existing workspace pre-migration. On
            // fresh DB this is a no-op. Filesystem errors swallowed — DB
            // migration must succeed even if keystore relocation fails.
            if let wid = firstWorkspaceID {
                _ = try? TeamKeystore.relocateLegacyTeamKeys(toWorkspaceID: wid)
            }
        }
    }
}
