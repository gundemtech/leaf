import Foundation
import GRDB

/// Phase 4.1 — the `integrations` table for OAuth credentials of Layer B providers.
/// PK on `provider` enforces single-row-per-provider (single-workspace MVP);
/// multi-workspace will require an M005 lift of the PK → composite (provider, workspace_id).
public extension DatabaseMigrator {
    mutating func registerMigration004Integrations() {
        registerMigration("004_integrations") { db in
            try db.create(table: Schema.Integrations.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.Integrations.provider, .text)
                t.column(Schema.Integrations.workspaceID, .text).notNull()
                t.column(Schema.Integrations.workspaceName, .text).notNull()
                t.column(Schema.Integrations.accessToken, .text).notNull()
                t.column(Schema.Integrations.refreshToken, .text)
                t.column(Schema.Integrations.expiresAtMs, .integer)
                t.column(Schema.Integrations.scope, .text).notNull()
                t.column(Schema.Integrations.connectedAtMs, .integer).notNull()
                t.column(Schema.Integrations.updatedMs, .integer).notNull()
            }
        }
    }
}
