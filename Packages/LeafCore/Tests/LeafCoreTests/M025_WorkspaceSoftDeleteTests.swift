// Track 5 / S7 — M025 `workspaces.deleted_at_ms` column + partial index schema check.

import XCTest
import GRDB
@testable import LeafCore

final class M025_WorkspaceSoftDeleteTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m025-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Column existence

    /// M025 — `workspaces.deleted_at_ms` column is added as nullable INTEGER.
    func testM025_AddsDeletedAtMsColumn() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.Workspaces.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            // Column must exist.
            let col = try XCTUnwrap(
                byName[Schema.Workspaces.deletedAtMs],
                "expected column \(Schema.Workspaces.deletedAtMs) in workspaces"
            )

            // INTEGER affinity (SQLite stores it as "INTEGER").
            let type = (col["type"] as String?).map { $0.uppercased() } ?? ""
            XCTAssertEqual(type, "INTEGER", "expected INTEGER affinity for deleted_at_ms")

            // Must be nullable (notnull == 0).
            XCTAssertEqual(col["notnull"] as Int?, 0, "deleted_at_ms must be nullable")

            // Must not be a primary key column.
            XCTAssertEqual(col["pk"] as Int?, 0, "deleted_at_ms must not be part of PK")
        }
    }

    // MARK: - Index existence

    /// M025 — partial index `idx_workspaces_active` exists on `workspaces`
    /// and its WHERE clause references both `deleted_at_ms` and `left_at_ms`.
    func testM025_CreatesPartialActiveIndex() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let indexNames = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.Workspaces.tableName]
            )
            XCTAssertTrue(
                indexNames.contains(Schema.Workspaces.indexActive),
                "expected index \(Schema.Workspaces.indexActive); found \(indexNames)"
            )

            let sql = try String.fetchOne(
                rawDB,
                sql: "SELECT sql FROM sqlite_master WHERE type='index' AND name=?",
                arguments: [Schema.Workspaces.indexActive]
            )
            let indexSQL = try XCTUnwrap(sql)
            let upper = indexSQL.uppercased()

            // Partial index must have a WHERE clause.
            XCTAssertTrue(upper.contains("WHERE"), "expected partial index; got: \(indexSQL)")

            // WHERE clause references deleted_at_ms.
            XCTAssertTrue(
                upper.contains(Schema.Workspaces.deletedAtMs.uppercased()),
                "WHERE must reference \(Schema.Workspaces.deletedAtMs); got: \(indexSQL)"
            )

            // WHERE clause references left_at_ms.
            XCTAssertTrue(
                upper.contains(Schema.Workspaces.leftAtMs.uppercased()),
                "WHERE must reference \(Schema.Workspaces.leftAtMs); got: \(indexSQL)"
            )

            // Both columns filtered to IS NULL.
            XCTAssertTrue(
                upper.contains("IS NULL"),
                "expected IS NULL predicate in partial index; got: \(indexSQL)"
            )
        }
    }

    // MARK: - Existing schema preserved

    /// M025 — pre-existing workspaces columns (M019 shape) remain intact after migration.
    func testM025_PreservesExistingWorkspacesColumns() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.Workspaces.tableName))"
            ).compactMap { $0["name"] as String? }

            let required: Set<String> = [
                Schema.Workspaces.id,
                Schema.Workspaces.name,
                Schema.Workspaces.createdAtMs,
                Schema.Workspaces.createdByMemberID,
                Schema.Workspaces.leftAtMs,
                Schema.Workspaces.deletedAtMs
            ]
            for col in required {
                XCTAssertTrue(columns.contains(col), "expected column \(col) in workspaces after M025")
            }
        }
    }

    // MARK: - Idempotency

    /// M025 — re-opening the same DB does not raise; GRDB migration guard prevents
    /// double-application of the migration.
    func testM025_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        // Second open must not throw.
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }
}
