// Phase Track-6 P4 — M030 `google_calendar_typed_event_tracker` migration
// coverage. Mirrors IntensityAggregatesStoreTests pattern (real Database open
// with deterministicTest encryption + writeSQL/readSQL handles).
//
// Renamed from dev M027 → M030 on the integration trunk (Ph B unification):
// slot M027 is InviteSystemRedesign here; GoogleCalendar appends after M029.

import GRDB
import XCTest

@testable import LeafCore

final class M030GoogleCalendarTrackerTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-gcal-tracker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDB() throws -> LeafCore.Database {
        try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testTableExistsAfterMigration() throws {
        let db = try openDB()
        try db.readSQL { rawDB in
            let exists = try Bool.fetchOne(
                rawDB,
                sql: """
                    SELECT count(*) > 0 FROM sqlite_master
                     WHERE type='table' AND name='google_calendar_typed_event_tracker'
                    """)
            XCTAssertEqual(exists, true)
        }
    }

    func testTableHasRequiredColumnsAndPK() throws {
        let db = try openDB()
        try db.readSQL { rawDB in
            let rows = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(google_calendar_typed_event_tracker)")
            let names: Set<String> = Set(rows.compactMap { $0["name"] as String? })
            XCTAssertEqual(
                names,
                [
                    "event_id", "calendar_id", "i_cal_uid", "event_type",
                    "start_ms", "end_ms",
                    "started_emitted_at_ms", "ended_emitted_at_ms",
                    "working_location_type",
                    "auto_decline_mode", "chat_status",
                    "upserted_at_ms",
                ])
            let pkRow = rows.first { ($0["pk"] as Int?) == 1 }
            XCTAssertEqual(pkRow?["name"] as String?, "event_id", "event_id must be the PK")
        }
    }

    func testPartialIndexesPresent() throws {
        let db = try openDB()
        try db.readSQL { rawDB in
            let indexNames: Set<String> = Set(
                try Row.fetchAll(
                    rawDB,
                    sql: """
                        SELECT name FROM sqlite_master
                         WHERE type='index' AND tbl_name='google_calendar_typed_event_tracker'
                        """
                )
                .compactMap { $0["name"] as String? }
            )
            XCTAssertTrue(indexNames.contains("idx_gcal_tracker_scan_started"))
            XCTAssertTrue(indexNames.contains("idx_gcal_tracker_scan_ended"))
            XCTAssertTrue(indexNames.contains("idx_gcal_tracker_by_calendar"))
        }
    }

    func testUpsertIdempotency() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                    INSERT INTO google_calendar_typed_event_tracker
                      (event_id, calendar_id, event_type, start_ms, end_ms, upserted_at_ms)
                    VALUES ('evt1', 'primary', 'focusTime', 1000, 2000, 500)
                    """)
            try rawDB.execute(
                sql: """
                    INSERT INTO google_calendar_typed_event_tracker
                      (event_id, calendar_id, event_type, start_ms, end_ms, upserted_at_ms)
                    VALUES ('evt1', 'primary', 'focusTime', 1000, 3000, 600)
                    ON CONFLICT(event_id) DO UPDATE SET
                        end_ms = excluded.end_ms,
                        upserted_at_ms = excluded.upserted_at_ms
                    """)
        }
        try db.readSQL { rawDB in
            let row = try Row.fetchOne(
                rawDB,
                sql: """
                    SELECT end_ms, upserted_at_ms FROM google_calendar_typed_event_tracker
                     WHERE event_id = 'evt1'
                    """
            )
            XCTAssertNotNil(row)
            XCTAssertEqual(row?["end_ms"] as Int64?, 3_000)
            XCTAssertEqual(row?["upserted_at_ms"] as Int64?, 600)
        }
    }
}
