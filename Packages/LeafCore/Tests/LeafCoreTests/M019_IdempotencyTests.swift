import XCTest
import GRDB
@testable import LeafCore

/// Track-5 S2 — M019 must be idempotent across re-open: GRDB tracks applied
/// identifiers in `grdb_migrations` and skips already-applied. Re-opening the
/// same encrypted-or-plaintext file should not change schema shape.
final class M019_IdempotencyTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("m019-idem-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    /// Open, capture team_keys column list, re-open, capture again. GRDB
    /// migrator skips M001..M019 the second pass; schema must be byte-identical.
    func testMigrate_Twice_StableSchema() throws {
        let db1 = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
        let cols1 = try db1.fetchTableColumns("team_keys").sorted()
        let wsCols1 = try db1.fetchTableColumns("workspaces").sorted()
        let indexes1 = try db1.fetchTableIndexes("team_members").sorted()

        // Drop reference — let GRDB DatabasePool release the file handle before re-open.
        _ = db1

        let db2 = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
        let cols2 = try db2.fetchTableColumns("team_keys").sorted()
        let wsCols2 = try db2.fetchTableColumns("workspaces").sorted()
        let indexes2 = try db2.fetchTableIndexes("team_members").sorted()

        XCTAssertEqual(cols1, cols2, "team_keys columns must be stable across re-open")
        XCTAssertEqual(wsCols1, wsCols2, "workspaces columns must be stable across re-open")
        XCTAssertEqual(indexes1, indexes2, "team_members indexes must be stable across re-open")
    }
}
