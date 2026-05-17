import Foundation
import GRDB

/// Phase Track-4 S3 — single record returned by `IntensityAggregatesStore.read`.
/// Counter-only — keycode/characters/modifierFlags никогда не материализуются
/// в этом типе (ADR-010 Won't-list). `foregroundApp` обнуляется flush'ем, если
/// bucket выпал на locked/sleeping window (см. `IntensityBucketAccumulator`).
public struct IntensityAggregateRecord: Sendable, Equatable {
    public let minuteBucketMs: Int64
    public let keystrokes: Int
    public let mouseMoves: Int
    public let appSwitches: Int
    public let foregroundApp: String?

    public init(
        minuteBucketMs: Int64,
        keystrokes: Int,
        mouseMoves: Int,
        appSwitches: Int,
        foregroundApp: String?
    ) {
        self.minuteBucketMs = minuteBucketMs
        self.keystrokes = keystrokes
        self.mouseMoves = mouseMoves
        self.appSwitches = appSwitches
        self.foregroundApp = foregroundApp
    }
}

/// Phase Track-4 S3 — DAO over `intensity_aggregates`. Static methods receive raw
/// `GRDB.Database` handle (caller wraps в pool.write/.read), mirror
/// `PendingInvitesStore` shape. UPSERT semantics через INSERT OR REPLACE по PK
/// `minute_bucket_ms` — повторный flush на restart идемпотентен.
public struct IntensityAggregatesStore: Sendable {

    public static func upsert(
        minuteBucketMs: Int64,
        keystrokes: Int,
        mouseMoves: Int,
        appSwitches: Int,
        foregroundApp: String?,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO \(Schema.IntensityAggregates.tableName) (
                    \(Schema.IntensityAggregates.minuteBucketMs),
                    \(Schema.IntensityAggregates.keystrokes),
                    \(Schema.IntensityAggregates.mouseMoves),
                    \(Schema.IntensityAggregates.appSwitches),
                    \(Schema.IntensityAggregates.foregroundApp)
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                minuteBucketMs,
                keystrokes,
                mouseMoves,
                appSwitches,
                foregroundApp,
            ]
        )
    }

    public static func read(
        range: Range<Int64>,
        in db: GRDB.Database
    ) throws -> [IntensityAggregateRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT \(Schema.IntensityAggregates.minuteBucketMs),
                       \(Schema.IntensityAggregates.keystrokes),
                       \(Schema.IntensityAggregates.mouseMoves),
                       \(Schema.IntensityAggregates.appSwitches),
                       \(Schema.IntensityAggregates.foregroundApp)
                FROM \(Schema.IntensityAggregates.tableName)
                WHERE \(Schema.IntensityAggregates.minuteBucketMs) >= ?
                  AND \(Schema.IntensityAggregates.minuteBucketMs) < ?
                ORDER BY \(Schema.IntensityAggregates.minuteBucketMs) ASC
                """,
            arguments: [range.lowerBound, range.upperBound]
        )
        return rows.map { row in
            IntensityAggregateRecord(
                minuteBucketMs: row[Schema.IntensityAggregates.minuteBucketMs],
                keystrokes: row[Schema.IntensityAggregates.keystrokes],
                mouseMoves: row[Schema.IntensityAggregates.mouseMoves],
                appSwitches: row[Schema.IntensityAggregates.appSwitches],
                foregroundApp: row[Schema.IntensityAggregates.foregroundApp]
            )
        }
    }

    public static func purge(
        before cutoffMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                DELETE FROM \(Schema.IntensityAggregates.tableName)
                WHERE \(Schema.IntensityAggregates.minuteBucketMs) < ?
                """,
            arguments: [cutoffMs]
        )
    }
}
