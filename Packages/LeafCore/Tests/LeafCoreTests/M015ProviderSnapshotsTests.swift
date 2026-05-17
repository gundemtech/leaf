import GRDB
import XCTest

@testable import LeafCore

final class M015ProviderSnapshotsTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m015-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testTableExistsAfterMigration() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.readSQL { rawDB in
            let row = try Row.fetchOne(
                rawDB, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='provider_snapshots'")
            XCTAssertNotNil(row, "provider_snapshots table must exist after migration")
        }
    }

    func testCompositePrimaryKeyEnforced() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql:
                    "INSERT INTO provider_snapshots (provider, snapshot_kind, snapshot_json, captured_at_ms) VALUES (?, ?, ?, ?)",
                arguments: ["linear", "linear_subscribed_issues", "{}", 1])
            // Second insert with same PK should fail
            XCTAssertThrowsError(
                try rawDB.execute(
                    sql:
                        "INSERT INTO provider_snapshots (provider, snapshot_kind, snapshot_json, captured_at_ms) VALUES (?, ?, ?, ?)",
                    arguments: ["linear", "linear_subscribed_issues", "{}", 2]))
        }
    }

    func testUpsertOverwritesSamePK() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql:
                    "INSERT INTO provider_snapshots (provider, snapshot_kind, snapshot_json, captured_at_ms) VALUES (?, ?, ?, ?) ON CONFLICT(provider, snapshot_kind) DO UPDATE SET snapshot_json=excluded.snapshot_json, captured_at_ms=excluded.captured_at_ms",
                arguments: ["linear", "linear_custom_views", "{\"v\":1}", 1])
            try rawDB.execute(
                sql:
                    "INSERT INTO provider_snapshots (provider, snapshot_kind, snapshot_json, captured_at_ms) VALUES (?, ?, ?, ?) ON CONFLICT(provider, snapshot_kind) DO UPDATE SET snapshot_json=excluded.snapshot_json, captured_at_ms=excluded.captured_at_ms",
                arguments: ["linear", "linear_custom_views", "{\"v\":2}", 2])
            let row = try Row.fetchOne(
                rawDB,
                sql:
                    "SELECT snapshot_json, captured_at_ms FROM provider_snapshots WHERE provider='linear' AND snapshot_kind='linear_custom_views'"
            )
            XCTAssertEqual(row?["snapshot_json"] as String?, "{\"v\":2}")
            XCTAssertEqual(row?["captured_at_ms"] as Int64?, 2)
        }
    }
}
