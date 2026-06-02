import Foundation
import GRDB

/// Registers migration 002 — adds the `collector_offsets` table for tail-read
/// collectors (Phase 2.3 Claude Code jsonl, Phase 2.4 FSEvents).
/// Schema namespace in `Schema.CollectorOffsets`. Composite PK (collector_id, source_id).
public extension DatabaseMigrator {
    mutating func registerMigration002CollectorOffsets() {
        registerMigration("002_collector_offsets") { db in
            try db.create(table: Schema.CollectorOffsets.tableName, ifNotExists: true) { t in
                t.column(Schema.CollectorOffsets.collectorID, .text).notNull()
                t.column(Schema.CollectorOffsets.sourceID, .text).notNull()
                t.column(Schema.CollectorOffsets.byteOffset, .integer).notNull().defaults(to: 0)
                t.column(Schema.CollectorOffsets.inode, .integer)
                t.column(Schema.CollectorOffsets.size, .integer).notNull().defaults(to: 0)
                t.column(Schema.CollectorOffsets.lastModifiedMs, .integer).notNull()
                t.column(Schema.CollectorOffsets.updatedMs, .integer).notNull()
                t.primaryKey([
                    Schema.CollectorOffsets.collectorID,
                    Schema.CollectorOffsets.sourceID
                ])
            }
        }
    }
}
