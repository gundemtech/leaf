import Foundation
import GRDB

/// Registers migration 001 — создаёт таблицу events и 2 индекса.
/// Schema structure публична (уже в architecture.md). SQL DDL — не moat.
public extension DatabaseMigrator {
    mutating func registerMigration001Events() {
        registerMigration("001_events") { db in
            try db.create(table: Schema.Events.tableName) { t in
                t.autoIncrementedPrimaryKey(Schema.Events.id)
                t.column(Schema.Events.ts, .integer).notNull()
                t.column(Schema.Events.signalType, .text).notNull()
                t.column(Schema.Events.bundleID, .text)
                t.column(Schema.Events.payloadJSON, .text).notNull().defaults(to: "{}")
            }

            try db.create(
                index: Schema.Events.indexTs,
                on: Schema.Events.tableName,
                columns: [Schema.Events.ts]
            )

            try db.create(
                index: Schema.Events.indexBundleTs,
                on: Schema.Events.tableName,
                columns: [Schema.Events.bundleID, Schema.Events.ts]
            )
        }
    }
}
