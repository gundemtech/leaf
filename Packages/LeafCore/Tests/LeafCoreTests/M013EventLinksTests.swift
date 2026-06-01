// Phase Track-1 D2 — M013 event_links table + reverse-lookup index.

import XCTest
import GRDB
@testable import LeafCore

final class M013EventLinksTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m013-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM013_CreatesTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tableNames = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: ["event_links"]
            )
            XCTAssertEqual(tableNames, ["event_links"])

            // Columns
            let columns = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(event_links)")
                .compactMap { $0["name"] as String? }
            XCTAssertEqual(
                Set(columns),
                Set(["from_event_id", "link_kind", "target_kind", "target_ref", "confidence", "created_at_ms"])
            )

            // Composite PK (from_event_id, link_kind, target_ref)
            let pkRows = try Row.fetchAll(rawDB, sql: "PRAGMA table_info(event_links)")
                .filter { ($0["pk"] as Int? ?? 0) > 0 }
                .sorted { ($0["pk"] as Int? ?? 0) < ($1["pk"] as Int? ?? 0) }
                .compactMap { $0["name"] as String? }
            XCTAssertEqual(pkRows, ["from_event_id", "link_kind", "target_ref"])

            // Reverse-lookup index
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
                arguments: ["idx_event_links_target"]
            )
            XCTAssertEqual(indexes, ["idx_event_links_target"])
        }
    }

    func testM013_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM013_FullSequenceRunsCleanly() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let applied = try String.fetchAll(rawDB, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            XCTAssertTrue(applied.contains("013_event_links"))
            // Track-5 S5: chain = 19 (S2) + M020+M021 (S4) + M022+M023+M024 (S5).
            // Track-5 S7: M025 (workspaces.deleted_at_ms + idx_workspaces_active).
            // Track-5 S8 T1: M026 (notification_prefs + ALTER messages_mirror.pending_mark_done).
            // M027 invite-redesign: invite_tokens + workspaces ADD COLUMN defaults.
            // M028 Track-6 P1 partial expression index (integration-T10).
            // M029 Track-6 P3 browser domain allow-list (integration-T10).
            // M030 Track-6 P4 GoogleCalendar tracker (Ph B trunk unification).
            XCTAssertEqual(applied.count, 30)
        }
    }
}
