import Foundation
import GRDB

/// Phase 4.1 — таблица `integrations` для OAuth credentials Layer B providers.
/// PK на `provider` фиксирует single-row-per-provider (single-workspace MVP);
/// multi-workspace потребует M005 lift PK → composite (provider, workspace_id).
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
