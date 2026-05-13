import Foundation
import GRDB

/// Phase Track-4 S3 — `intensity_aggregates` per-minute counter-only rollup
/// populated by `CGEventTapCollector` minute-boundary flush. PK
/// `minute_bucket_ms` (minute-truncated epoch ms). UPSERT semantics — re-flush
/// on restart replaces existing row idempotently. Counter columns counter-only;
/// keycode/characters/modifierFlags никогда не пишутся (ADR-010 Won't-list).
public extension DatabaseMigrator {
    mutating func registerMigration018IntensityAggregates() {
        registerMigration("018_intensity_aggregates") { db in
            try db.create(table: Schema.IntensityAggregates.tableName, ifNotExists: true) { t in
                t.column(Schema.IntensityAggregates.minuteBucketMs, .integer).primaryKey().notNull()
                t.column(Schema.IntensityAggregates.keystrokes, .integer).notNull().defaults(to: 0)
                t.column(Schema.IntensityAggregates.mouseMoves, .integer).notNull().defaults(to: 0)
                t.column(Schema.IntensityAggregates.appSwitches, .integer).notNull().defaults(to: 0)
                t.column(Schema.IntensityAggregates.foregroundApp, .text)
            }

            try db.create(
                index: Schema.IntensityAggregates.indexBucket,
                on: Schema.IntensityAggregates.tableName,
                columns: [Schema.IntensityAggregates.minuteBucketMs],
                ifNotExists: true
            )
        }
    }
}
