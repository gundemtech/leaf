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
            XCTAssertEqual(applied.count, 18)
        }
    }
}
