import Foundation
import GRDB

/// Phase 5.1.A — `org` organization metadata table (1 row per device).
/// Single-org-per-device per Phase 5 architecture contract §11.
/// Schema structure публична (whitepaper storage.md). SQL DDL — не moat.
///
/// `created_by_member_id` — logical FK на `team_members.id`; SQL FOREIGN KEY
/// не объявляется (см. spec 5.1.A §4 — insertion order paradox + foreign_keys
/// pragma не enabled).
extension DatabaseMigrator {
    public mutating func registerMigration006Org() {
        registerMigration("006_org") { db in
            try db.create(table: Schema.Org.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.Org.id, .text)
                t.column(Schema.Org.name, .text).notNull()
                t.column(Schema.Org.createdAtMs, .integer).notNull()
                t.column(Schema.Org.createdByMemberID, .text).notNull()
            }
        }
    }
}
