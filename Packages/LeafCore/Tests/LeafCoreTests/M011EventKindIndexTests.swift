// Phase Track-1 D1 — M011 expression index on events.payload_json->>'event_kind'.

import XCTest
import GRDB
@testable import LeafCore

final class M011EventKindIndexTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m011-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM011_CreatesIndex() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let names = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
                arguments: ["idx_events_event_kind_ts"]
            )
            XCTAssertEqual(names, ["idx_events_event_kind_ts"])

            let sqlRow = try Row.fetchOne(
                rawDB,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
                arguments: ["idx_events_event_kind_ts"]
            )
            let sqlStr = (sqlRow?["sql"] as String?) ?? ""
            XCTAssertTrue(sqlStr.contains("json_extract"), "Expression index should reference json_extract")
            XCTAssertTrue(sqlStr.contains("$.event_kind"), "Expression index should target $.event_kind")
        }
    }

    func testM011_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM011_FullSequenceRunsCleanly() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let applied = try String.fetchAll(rawDB, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            XCTAssertTrue(applied.contains("011_event_kind_index"))
            // Track-5 S5: chain extended by M020 (messages_mirror) + M021 (apns_token_local) +
            // M022 (share_rules) + M023 (team_events_mirror) + M024 (team_event_broadcast_offsets).
            // Track-5 S7: M025 (workspaces.deleted_at_ms + idx_workspaces_active).
            // Track-5 S8 T1: M026 (notification_prefs + ALTER messages_mirror.pending_mark_done).
            XCTAssertEqual(applied.count, 26)
        }
    }
}
