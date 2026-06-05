// Ph B W1 / B4a — upgrade-path coverage for the M030 GoogleCalendar tracker.
//
// CTO finding F6: the dangerous case for Ph B is NOT a fresh DB, it's an
// EXISTING alpha.22 / M029 database opened by the new (M001–M030) binary —
// the "Couldn't load Home" symptom is a runtime schema-shape mismatch when a
// binary opens a DB whose migration ledger it doesn't match. This test
// simulates that upgrade: take a fully-migrated DB, roll its ledger + schema
// back to the M029 state, then reopen with the production migrator and assert
// (a) M030 re-applies cleanly, (b) the GCal table is (re)created, and
// (c) a representative read still succeeds — i.e. Home would load.

import GRDB
import XCTest

@testable import LeafCore

final class M030UpgradeFromM029Tests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m030-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDB() throws -> LeafCore.Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    /// Simulate "existing M029 DB opened by an M030 binary": migrate fully,
    /// then roll back to the M029 state (drop the GCal table + delete its
    /// ledger row), reopen, and assert M030 re-applies + Home-equivalent read.
    func testExistingM029DBUpgradesToM030Cleanly() throws {
        // 1. Fresh open → fully migrated to M030.
        let first = try openDB()
        try first.writeSQL { rawDB in
            // Roll back to the M029 ledger state: forget M030 + drop its table,
            // mimicking a DB that was created before M030 existed.
            try rawDB.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = '030_google_calendar_typed_event_tracker'")
            try rawDB.execute(sql: "DROP TABLE IF EXISTS google_calendar_typed_event_tracker")
        }
        // Confirm the rollback actually produced an "M029-shaped" DB.
        try first.readSQL { rawDB in
            let hasM030 = try Bool.fetchOne(
                rawDB,
                sql: """
                    SELECT count(*) > 0 FROM grdb_migrations
                     WHERE identifier = '030_google_calendar_typed_event_tracker'
                    """)
            XCTAssertEqual(hasM030, false, "precondition: ledger rolled back to M029 state")
            let hasTable = try Bool.fetchOne(
                rawDB,
                sql: """
                    SELECT count(*) > 0 FROM sqlite_master
                     WHERE type='table' AND name='google_calendar_typed_event_tracker'
                    """)
            XCTAssertEqual(hasTable, false, "precondition: GCal table dropped")
        }

        // 2. Reopen with the production migrator (M001–M030) — the upgrade.
        let upgraded = try openDB()

        // 3a. M030 re-applied — ledger advanced.
        try upgraded.readSQL { rawDB in
            let applied = try String.fetchAll(rawDB, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertTrue(
                applied.contains("030_google_calendar_typed_event_tracker"),
                "M030 must apply when an M029-era DB is opened by the M030 binary")
            XCTAssertEqual(applied.count, 32, "full ledger M001–M032 after upgrade")
        }

        // 3b. GCal table is back with its PK + partial indexes.
        try upgraded.readSQL { rawDB in
            let cols: Set<String> = Set(
                try Row.fetchAll(rawDB, sql: "PRAGMA table_info(google_calendar_typed_event_tracker)")
                    .compactMap { $0["name"] as String? })
            XCTAssertTrue(cols.contains("event_id"))
            XCTAssertTrue(cols.contains("event_type"))
            let indexes: Set<String> = Set(
                try Row.fetchAll(
                    rawDB,
                    sql: """
                        SELECT name FROM sqlite_master
                         WHERE type='index' AND tbl_name='google_calendar_typed_event_tracker'
                        """)
                    .compactMap { $0["name"] as String? })
            XCTAssertTrue(indexes.contains("idx_gcal_tracker_scan_started"))
        }

        // 3c. "Home loads": a representative read against the pre-existing
        // events table still succeeds after the upgrade (no schema-shape break).
        try upgraded.readSQL { rawDB in
            let eventCount = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM events")
            XCTAssertNotNil(eventCount, "events table readable after upgrade — Home would load")
        }
    }
}
