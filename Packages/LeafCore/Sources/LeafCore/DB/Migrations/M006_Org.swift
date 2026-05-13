import Foundation
import GRDB

/// Phase 5.1.A — `org` organization metadata table (1 row per device).
/// Single-org-per-device per Phase 5 architecture contract §11.
/// Schema structure публична (whitepaper storage.md). SQL DDL — не moat.
///
/// `created_by_member_id` — logical FK на `team_members.id`; SQL FOREIGN KEY
/// не объявляется (см. spec 5.1.A §4 — insertion order paradox + foreign_keys
/// pragma не enabled).
public extension DatabaseMigrator {
    mutating func registerMigration006Org() {
        // Track-5 S2: historical migration — hardcoded string literals because
        // `Schema.Org` is now a typealias to `Schema.Workspaces` (post-M019
        // naming). M006 ran historically as `org`; M019 then renames →
        // `workspaces`. Schema constants must not bleed forward into history.
        registerMigration("006_org") { db in
            try db.create(table: "org", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("created_at_ms", .integer).notNull()
                t.column("created_by_member_id", .text).notNull()
            }
        }
    }
}
