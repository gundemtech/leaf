import Foundation
import GRDB

public extension DatabaseMigrator {
    /// Track 5 / S7 — adds `workspaces.deleted_at_ms` column for admin soft-delete UX.
    /// Cascade-DELETE of workspace-scoped rows (team_members, team_keys, etc.) is
    /// deferred to Task E.2. Partial index `idx_workspaces_active` accelerates the
    /// hot-path "list active workspaces" query (WHERE deleted_at_ms IS NULL AND
    /// left_at_ms IS NULL).
    mutating func registerMigration025WorkspaceSoftDelete() {
        registerMigration("025_workspace_soft_delete") { db in
            try db.alter(table: Schema.Workspaces.tableName) { t in
                t.add(column: Schema.Workspaces.deletedAtMs, .integer)
            }
            try db.create(
                index: Schema.Workspaces.indexActive,
                on: Schema.Workspaces.tableName,
                columns: [Schema.Workspaces.id],
                condition: Column(Schema.Workspaces.deletedAtMs) == nil
                    && Column(Schema.Workspaces.leftAtMs) == nil
            )
        }
    }
}
