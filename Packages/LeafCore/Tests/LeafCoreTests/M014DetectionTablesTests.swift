// Phase Track-1 D3 — M014 detection tables migration.
//
// 5 new tables (decisions / open_questions / blockers / where_stopped_log /
// detector_offsets) + 8 indexes + 3 pre-seeded `detector_offsets` rows.
// Logical FKs to `events.id` only (repo convention — see M013_EventLinks.swift
// + Schema.swift §74-75, §219). No SQL `FOREIGN KEY` declarations.

import GRDB
import XCTest

@testable import LeafCore

final class M014DetectionTablesTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m014-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDB() throws -> LeafCore.Database {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        return try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    // MARK: - Tests

    func testMigrationCreatesAllFiveTables() throws {
        let db = try openDB()
        try db.readSQL { rawDB in
            for table in [
                "decisions", "open_questions", "blockers",
                "where_stopped_log", "detector_offsets",
            ] {
                let exists = try Bool.fetchOne(
                    rawDB,
                    sql: """
                            SELECT count(*) > 0 FROM sqlite_master
                             WHERE type='table' AND name=?
                        """, arguments: [table])
                XCTAssertEqual(exists, true, "Missing table \(table)")
            }
        }
    }

    func testEventIDColumnIsLogicalFK() throws {
        // Repo convention — no SQL FOREIGN KEY declarations. We assert the
        // logical-FK column is present and typed INTEGER on each detection
        // table that links back to events.id.
        let db = try openDB()
        try db.readSQL { rawDB in
            // decisions.event_id INTEGER NOT NULL UNIQUE
            let decisionsCols = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(decisions)")
            let decisionEventID = decisionsCols.first { ($0["name"] as String?) == "event_id" }
            XCTAssertNotNil(decisionEventID)
            XCTAssertEqual(decisionEventID?["type"] as String?, "INTEGER")
            XCTAssertEqual((decisionEventID?["notnull"] as Int?) ?? 0, 1)

            // open_questions.event_id INTEGER NOT NULL UNIQUE; resolved_by_event_id INTEGER NULL
            let oqCols = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(open_questions)")
            let oqEventID = oqCols.first { ($0["name"] as String?) == "event_id" }
            XCTAssertEqual(oqEventID?["type"] as String?, "INTEGER")
            XCTAssertEqual((oqEventID?["notnull"] as Int?) ?? 0, 1)
            let oqResolvedBy = oqCols.first { ($0["name"] as String?) == "resolved_by_event_id" }
            XCTAssertEqual(oqResolvedBy?["type"] as String?, "INTEGER")
            XCTAssertEqual((oqResolvedBy?["notnull"] as Int?) ?? 1, 0)

            // blockers.detected_by_event_id, resolved_by_event_id — both nullable INTEGER
            let blockerCols = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(blockers)")
            let detectedBy = blockerCols.first { ($0["name"] as String?) == "detected_by_event_id" }
            XCTAssertEqual(detectedBy?["type"] as String?, "INTEGER")
            let blockerResolvedBy = blockerCols.first { ($0["name"] as String?) == "resolved_by_event_id" }
            XCTAssertEqual(blockerResolvedBy?["type"] as String?, "INTEGER")

            // where_stopped_log.anchor_event_id — nullable INTEGER
            let wsCols = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(where_stopped_log)")
            let anchor = wsCols.first { ($0["name"] as String?) == "anchor_event_id" }
            XCTAssertEqual(anchor?["type"] as String?, "INTEGER")
        }
    }

    func testPartialUniqueIndexBlockersOpen() throws {
        let db = try openDB()
        try db.writeSQL { rawDB in
            // Two open blockers same target — second insert must fail
            try rawDB.execute(
                sql: """
                        INSERT INTO blockers (target_kind, target_ref, blocker_kind, started_at_ms)
                        VALUES ('linear_issue', 'LEAF-1', 'linear_stuck', 1000)
                    """)
            XCTAssertThrowsError(
                try rawDB.execute(
                    sql: """
                            INSERT INTO blockers (target_kind, target_ref, blocker_kind, started_at_ms)
                            VALUES ('linear_issue', 'LEAF-1', 'linear_stuck', 2000)
                        """))
            // Resolved + open same target — OK
            try rawDB.execute(
                sql: """
                        UPDATE blockers SET resolved_at_ms = 1500 WHERE target_ref = 'LEAF-1'
                    """)
            try rawDB.execute(
                sql: """
                        INSERT INTO blockers (target_kind, target_ref, blocker_kind, started_at_ms)
                        VALUES ('linear_issue', 'LEAF-1', 'linear_stuck', 2000)
                    """)
        }
    }

    func testDetectorOffsetsPreSeeded() throws {
        let db = try openDB()
        let kinds = try db.readSQL { rawDB -> [String] in
            try String.fetchAll(
                rawDB,
                sql:
                    "SELECT detector_kind FROM detector_offsets ORDER BY detector_kind")
        }
        XCTAssertEqual(kinds, ["blocker_pattern", "decision", "open_question"])
    }

    func testIdempotentReRun() throws {
        // Migrator must be no-op on already-applied migration — re-opening
        // the same DB file runs the migrator chain a second time.
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }
}
