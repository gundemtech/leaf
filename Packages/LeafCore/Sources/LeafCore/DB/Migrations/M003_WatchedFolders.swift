import Foundation
import GRDB

/// Registers migration 003 — adds the `watched_folders` table for the Phase 2.4
/// FSEvents content collector. The user manages the list via the Settings UI.
/// `id` — UUID, PK; `path` — canonical absolute (after `resolvingSymlinksInPath`),
/// UNIQUE to prevent duplicates; `max_granularity` — `'L4'` (folder only)
/// or `'L5'` (full path) — applied in the router at write-time.
public extension DatabaseMigrator {
    mutating func registerMigration003WatchedFolders() {
        registerMigration("003_watched_folders") { db in
            try db.create(table: Schema.WatchedFolders.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.WatchedFolders.id, .text)
                t.column(Schema.WatchedFolders.path, .text).notNull().unique()
                // CHECK via raw SQL — the GRDB DSL has no idiomatic IN clause;
                // TableDefinition.check(sql:) is the standard escape hatch.
                t.column(Schema.WatchedFolders.maxGranularity, .text).notNull()
                t.column(Schema.WatchedFolders.enabled, .integer).notNull().defaults(to: 1)
                t.column(Schema.WatchedFolders.addedTs, .integer).notNull()
                t.column(Schema.WatchedFolders.updatedMs, .integer).notNull()
                t.check(sql: "\(Schema.WatchedFolders.maxGranularity) IN ('L4','L5')")
            }
            try db.create(
                index: Schema.WatchedFolders.indexEnabled,
                on: Schema.WatchedFolders.tableName,
                columns: [Schema.WatchedFolders.enabled],
                ifNotExists: true
            )
        }
    }
}
