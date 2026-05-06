import XCTest
import Foundation
import GRDB
@testable import LeafCore

/// Phase 5.3.D — `rotation_outbox` write-ahead journal helpers.
/// Sanity coverage of M009 migration here; full `commitRotation` / `markPosted`
/// / `readUnposted` coverage extended in Tasks 5-7.
final class DatabaseRotationOutboxTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-rotationoutbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM009MigrationCreatesRotationOutboxTable() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        // Verify table exists by issuing a SELECT — non-existent table would throw.
        let count: Int = try db.writeSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.RotationOutbox.tableName)") ?? -1
        }
        XCTAssertEqual(count, 0)
    }
}
