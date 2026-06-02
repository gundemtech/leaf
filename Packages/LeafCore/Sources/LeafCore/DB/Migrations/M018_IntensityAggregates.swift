import Foundation
import GRDB

/// Phase Track-4 S3 — `intensity_aggregates` per-minute counter-only rollup
/// populated by `CGEventTapCollector` minute-boundary flush. PK
/// `minute_bucket_ms` (minute-truncated epoch ms). UPSERT semantics — re-flush
/// on restart replaces existing row idempotently. Counter columns counter-only;
/// keycode/characters/modifierFlags are never written (ADR-010 Won't-list).
public extension DatabaseMigrator {
    mutating func registerMigration018IntensityAggregates() {
        registerMigration("018_intensity_aggregates") { db in
            // PK on minute_bucket_ms — SQLite auto-creates a B-tree index on
            // the PK column, no explicit `CREATE INDEX` needed for range scans
            // (retention purge + read(range:)).
            try db.create(table: Schema.IntensityAggregates.tableName, ifNotExists: true) { t in
                t.column(Schema.IntensityAggregates.minuteBucketMs, .integer).primaryKey().notNull()
                t.column(Schema.IntensityAggregates.keystrokes, .integer).notNull().defaults(to: 0)
                t.column(Schema.IntensityAggregates.mouseMoves, .integer).notNull().defaults(to: 0)
                t.column(Schema.IntensityAggregates.appSwitches, .integer).notNull().defaults(to: 0)
                t.column(Schema.IntensityAggregates.foregroundApp, .text)
            }
        }
    }
}
