import Foundation
import GRDB

/// Registers migration 003 — добавляет таблицу `watched_folders` для Phase 2.4
/// FSEvents content collector. Юзер управляет списком через Settings UI.
/// `id` — UUID, PK; `path` — canonical absolute (after `resolvingSymlinksInPath`),
/// UNIQUE для предотвращения дубликатов; `max_granularity` — `'L4'` (folder только)
/// или `'L5'` (full path) — применяется в router'е at write-time.
public extension DatabaseMigrator {
    mutating func registerMigration003WatchedFolders() {
        registerMigration("003_watched_folders") { db in
            try db.create(table: Schema.WatchedFolders.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.WatchedFolders.id, .text)
                t.column(Schema.WatchedFolders.path, .text).notNull().unique()
                // CHECK через raw SQL — GRDB DSL не имеет idiomatic IN-кляуза;
                // TableDefinition.check(sql:) — стандартный escape hatch.
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
