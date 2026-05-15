// Phase Track-5 S5 — M022 `share_rules` schema check.

import XCTest
import GRDB
@testable import LeafCore

final class M022ShareRulesTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m022-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM022_CreatesTableAndIndex() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.ShareRules.tableName]
            )
            XCTAssertEqual(tables, [Schema.ShareRules.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.ShareRules.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })
            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.ShareRules.workspaceID,
                    Schema.ShareRules.sourceKind,
                    Schema.ShareRules.enabled,
                    Schema.ShareRules.updatedAtMs
                ])
            )

            // Composite PK on (workspace_id, source_kind) — both columns with pk > 0.
            let wsRow = try XCTUnwrap(byName[Schema.ShareRules.workspaceID])
            let srcRow = try XCTUnwrap(byName[Schema.ShareRules.sourceKind])
            XCTAssertGreaterThan(wsRow["pk"] as Int? ?? 0, 0)
            XCTAssertGreaterThan(srcRow["pk"] as Int? ?? 0, 0)

            // All NOT NULL.
            for col in [
                Schema.ShareRules.workspaceID,
                Schema.ShareRules.sourceKind,
                Schema.ShareRules.enabled,
                Schema.ShareRules.updatedAtMs
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) should be NOT NULL")
            }

            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.ShareRules.tableName]
            )
            XCTAssertTrue(
                indexes.contains(Schema.ShareRules.indexWorkspace),
                "expected index \(Schema.ShareRules.indexWorkspace); found \(indexes)"
            )
        }
    }

    func testM022_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM022_TableEmptyAfterFreshMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.ShareRules.tableName)")
            XCTAssertEqual(count, 0)
        }
    }

    func testM022_AcceptsValidSourceKindAndRejectsDuplicateComposite() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                    INSERT INTO \(Schema.ShareRules.tableName) (
                        \(Schema.ShareRules.workspaceID),
                        \(Schema.ShareRules.sourceKind),
                        \(Schema.ShareRules.enabled),
                        \(Schema.ShareRules.updatedAtMs)
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: ["wid1", Schema.ShareSources.gitCommits, 1, 1_000]
            )
        }

        // Duplicate composite PK rejected.
        XCTAssertThrowsError(
            try db.writeSQL { rawDB in
                try rawDB.execute(
                    sql: """
                        INSERT INTO \(Schema.ShareRules.tableName) (
                            \(Schema.ShareRules.workspaceID),
                            \(Schema.ShareRules.sourceKind),
                            \(Schema.ShareRules.enabled),
                            \(Schema.ShareRules.updatedAtMs)
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: ["wid1", Schema.ShareSources.gitCommits, 0, 2_000]
                )
            }
        )

        // Different source_kind same workspace → allowed.
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                    INSERT INTO \(Schema.ShareRules.tableName) (
                        \(Schema.ShareRules.workspaceID),
                        \(Schema.ShareRules.sourceKind),
                        \(Schema.ShareRules.enabled),
                        \(Schema.ShareRules.updatedAtMs)
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: ["wid1", Schema.ShareSources.linearIssues, 1, 1_000]
            )
        }

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.ShareRules.tableName)")
            XCTAssertEqual(count, 2)
        }
    }
}
