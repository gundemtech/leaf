// Phase Track-4 S3 — IntensityAggregatesStore CRUD + M018 migration coverage.
// Mirrors PendingInvitesStore pattern (static methods over GRDB.Database handle).

import XCTest
import GRDB
@testable import LeafCore

final class IntensityAggregatesStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-intensity-aggregates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDB() throws -> LeafCore.Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testUpsertRoundTrip() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try IntensityAggregatesStore.upsert(
                minuteBucketMs: 1_000,
                keystrokes: 5,
                mouseMoves: 10,
                appSwitches: 1,
                foregroundApp: "com.apple.dt.Xcode",
                in: rawDB
            )
        }
        try db.readSQL { rawDB in
            let rows = try IntensityAggregatesStore.read(range: 0..<2_000, in: rawDB)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].minuteBucketMs, 1_000)
            XCTAssertEqual(rows[0].keystrokes, 5)
            XCTAssertEqual(rows[0].mouseMoves, 10)
            XCTAssertEqual(rows[0].appSwitches, 1)
            XCTAssertEqual(rows[0].foregroundApp, "com.apple.dt.Xcode")
        }
    }

    func testUpsertReplacesExisting() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try IntensityAggregatesStore.upsert(
                minuteBucketMs: 1_000,
                keystrokes: 5, mouseMoves: 10, appSwitches: 1,
                foregroundApp: "com.apple.dt.Xcode", in: rawDB
            )
            try IntensityAggregatesStore.upsert(
                minuteBucketMs: 1_000,
                keystrokes: 100, mouseMoves: 200, appSwitches: 3,
                foregroundApp: "com.apple.Safari", in: rawDB
            )
        }
        try db.readSQL { rawDB in
            let rows = try IntensityAggregatesStore.read(range: 0..<2_000, in: rawDB)
            XCTAssertEqual(rows.count, 1, "INSERT OR REPLACE must collapse duplicates by PK")
            XCTAssertEqual(rows[0].keystrokes, 100)
            XCTAssertEqual(rows[0].foregroundApp, "com.apple.Safari")
        }
    }

    func testReadEmptyRange() throws {
        let db = try openDB()
        try db.readSQL { rawDB in
            let rows = try IntensityAggregatesStore.read(range: 0..<1_000, in: rawDB)
            XCTAssertEqual(rows.count, 0)
        }
    }

    func testReadMultipleRowsOrderedAscending() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            for bucket in [180_000, 0, 60_000, 240_000, 120_000] as [Int64] {
                try IntensityAggregatesStore.upsert(
                    minuteBucketMs: bucket, keystrokes: 1, mouseMoves: 1, appSwitches: 0,
                    foregroundApp: nil, in: rawDB
                )
            }
        }
        try db.readSQL { rawDB in
            let rows = try IntensityAggregatesStore.read(range: 60_000..<240_000, in: rawDB)
            XCTAssertEqual(rows.map(\.minuteBucketMs), [60_000, 120_000, 180_000])
        }
    }

    func testPurgeRemovesOldRows() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            for bucket in [0, 60_000, 120_000] as [Int64] {
                try IntensityAggregatesStore.upsert(
                    minuteBucketMs: bucket, keystrokes: 0, mouseMoves: 0, appSwitches: 0,
                    foregroundApp: nil, in: rawDB
                )
            }
        }
        try db.writeSQL { rawDB in
            try IntensityAggregatesStore.purge(before: 90_000, in: rawDB)
        }
        try db.readSQL { rawDB in
            let rows = try IntensityAggregatesStore.read(range: 0..<200_000, in: rawDB)
            XCTAssertEqual(rows.map(\.minuteBucketMs), [120_000])
        }
    }

    func testPurgeIdempotent() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try IntensityAggregatesStore.upsert(
                minuteBucketMs: 60_000, keystrokes: 1, mouseMoves: 1, appSwitches: 0,
                foregroundApp: nil, in: rawDB
            )
            try IntensityAggregatesStore.purge(before: 30_000, in: rawDB)
            try IntensityAggregatesStore.purge(before: 30_000, in: rawDB)
        }
        try db.readSQL { rawDB in
            let rows = try IntensityAggregatesStore.read(range: 0..<200_000, in: rawDB)
            XCTAssertEqual(rows.count, 1)
        }
    }

    func testForegroundAppNullable() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try IntensityAggregatesStore.upsert(
                minuteBucketMs: 1_000, keystrokes: 0, mouseMoves: 0, appSwitches: 0,
                foregroundApp: nil, in: rawDB
            )
        }
        try db.readSQL { rawDB in
            let rows = try IntensityAggregatesStore.read(range: 0..<2_000, in: rawDB)
            XCTAssertEqual(rows.count, 1)
            XCTAssertNil(rows[0].foregroundApp)
        }
    }

    func testM018CreatesTable() throws {
        let db = try openDB()
        try db.readSQL { rawDB in
            let tableExists = try Bool.fetchOne(rawDB, sql: """
                SELECT count(*) > 0 FROM sqlite_master
                 WHERE type='table' AND name='intensity_aggregates'
                """)
            XCTAssertEqual(tableExists, true)
            // `INTEGER PRIMARY KEY` aliases rowid in SQLite — no separate
            // sqlite_autoindex row is created. Range scans / lookups use
            // the implicit rowid B-tree. Explicit CREATE INDEX redundant.
            let pkColumn = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(intensity_aggregates)")
                .first { ($0["name"] as String?) == "minute_bucket_ms" }
            XCTAssertEqual((pkColumn?["pk"] as Int?) ?? 0, 1, "minute_bucket_ms must be the PK")
        }
    }
}
