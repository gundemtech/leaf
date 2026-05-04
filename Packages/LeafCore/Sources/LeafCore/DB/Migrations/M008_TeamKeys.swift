import Foundation
import GRDB

/// Phase 5.1.A — `team_keys` rotation history (Phase 5 architecture contract §7).
/// Schema публична (whitepaper storage.md). SQL DDL — не moat.
///
/// PK = `id` UUID v4 (rotation identity; embedded as 16-byte `keyID` в envelope §6).
/// `deprecated_at_ms` IS NULL = current rotation; устанавливается в Phase 5.3.
/// `generated_by_member_id` — logical FK на `team_members.id` (audit who created
/// rotation); SQL FOREIGN KEY не объявляется (см. spec 5.1.A §4).
///
/// **Forever-retained** — old rows нужны для decrypt'а `presence_history`,
/// зашифрованной под past keys (contract §12). Никакого GC без явного user action.
///
/// Partial index `team_keys_active` — query "current key" дёшево (1 row).
public extension DatabaseMigrator {
    mutating func registerMigration008TeamKeys() {
        registerMigration("008_team_keys") { db in
            try db.create(table: Schema.TeamKeys.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.TeamKeys.id, .text)
                t.column(Schema.TeamKeys.generatedAtMs, .integer).notNull()
                t.column(Schema.TeamKeys.deprecatedAtMs, .integer)
                t.column(Schema.TeamKeys.generatedByMemberID, .text).notNull()
            }

            try db.create(
                index: Schema.TeamKeys.indexActive,
                on: Schema.TeamKeys.tableName,
                columns: [Schema.TeamKeys.deprecatedAtMs],
                condition: Column(Schema.TeamKeys.deprecatedAtMs) == nil
            )
        }
    }
}
