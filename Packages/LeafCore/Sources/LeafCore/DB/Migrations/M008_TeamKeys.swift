import Foundation
import GRDB

/// Phase 5.1.A — `team_keys` rotation history (Phase 5 architecture contract §7).
/// The schema is public (whitepaper storage.md). SQL DDL is not moat.
///
/// PK = `id` UUID v4 (rotation identity; embedded as 16-byte `keyID` in envelope §6).
/// `deprecated_at_ms` IS NULL = current rotation; set in Phase 5.3.
/// `generated_by_member_id` — logical FK to `team_members.id` (audit who created
/// the rotation); no SQL FOREIGN KEY is declared (see spec 5.1.A §4).
///
/// **Forever-retained** — old rows are needed to decrypt `presence_history`
/// encrypted under past keys (contract §12). No GC without an explicit user action.
///
/// Partial index `team_keys_active` — makes the "current key" query cheap (1 row).
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
