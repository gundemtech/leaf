// Phase Track-5 S5 — M023 `team_events_mirror` schema check.

import XCTest
import GRDB
@testable import LeafCore

final class M023TeamEventsMirrorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m023-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM023_CreatesTableAndIndexes() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.TeamEventsMirror.tableName]
            )
            XCTAssertEqual(tables, [Schema.TeamEventsMirror.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.TeamEventsMirror.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.TeamEventsMirror.eventID,
                    Schema.TeamEventsMirror.workspaceID,
                    Schema.TeamEventsMirror.senderPubkeyHex,
                    Schema.TeamEventsMirror.sourceKind,
                    Schema.TeamEventsMirror.kind,
                    Schema.TeamEventsMirror.plaintextPayloadJSON,
                    Schema.TeamEventsMirror.serverCreatedAtMs,
                    Schema.TeamEventsMirror.eventTsMs,
                    Schema.TeamEventsMirror.receivedAtMs
                ])
            )

            // Composite PK on (workspace_id, event_id).
            let widRow = try XCTUnwrap(byName[Schema.TeamEventsMirror.workspaceID])
            let eidRow = try XCTUnwrap(byName[Schema.TeamEventsMirror.eventID])
            XCTAssertGreaterThan(widRow["pk"] as Int? ?? 0, 0)
            XCTAssertGreaterThan(eidRow["pk"] as Int? ?? 0, 0)

            for col in [
                Schema.TeamEventsMirror.eventID,
                Schema.TeamEventsMirror.workspaceID,
                Schema.TeamEventsMirror.senderPubkeyHex,
                Schema.TeamEventsMirror.sourceKind,
                Schema.TeamEventsMirror.kind,
                Schema.TeamEventsMirror.plaintextPayloadJSON,
                Schema.TeamEventsMirror.serverCreatedAtMs,
                Schema.TeamEventsMirror.eventTsMs,
                Schema.TeamEventsMirror.receivedAtMs
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) should be NOT NULL")
            }

            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.TeamEventsMirror.tableName]
            )
            for idx in [
                Schema.TeamEventsMirror.indexWorkspaceCreated,
                Schema.TeamEventsMirror.indexSender
            ] {
                XCTAssertTrue(
                    indexes.contains(idx),
                    "expected index \(idx); found \(indexes)"
                )
            }
        }
    }

    func testM023_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM023_TableEmptyAfterFreshMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.TeamEventsMirror.tableName)")
            XCTAssertEqual(count, 0)
        }
    }

    func testM023_AllowsSameEventIDAcrossWorkspaces() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                    INSERT INTO \(Schema.TeamEventsMirror.tableName) (
                        \(Schema.TeamEventsMirror.eventID),
                        \(Schema.TeamEventsMirror.workspaceID),
                        \(Schema.TeamEventsMirror.senderPubkeyHex),
                        \(Schema.TeamEventsMirror.sourceKind),
                        \(Schema.TeamEventsMirror.kind),
                        \(Schema.TeamEventsMirror.plaintextPayloadJSON),
                        \(Schema.TeamEventsMirror.serverCreatedAtMs),
                        \(Schema.TeamEventsMirror.eventTsMs),
                        \(Schema.TeamEventsMirror.receivedAtMs)
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "evt1", "wid1", "shex", Schema.ShareSources.gitCommits, "gh_commit_pushed",
                    "{}", 1_000, 990, 1_010
                ]
            )
            try rawDB.execute(
                sql: """
                    INSERT INTO \(Schema.TeamEventsMirror.tableName) (
                        \(Schema.TeamEventsMirror.eventID),
                        \(Schema.TeamEventsMirror.workspaceID),
                        \(Schema.TeamEventsMirror.senderPubkeyHex),
                        \(Schema.TeamEventsMirror.sourceKind),
                        \(Schema.TeamEventsMirror.kind),
                        \(Schema.TeamEventsMirror.plaintextPayloadJSON),
                        \(Schema.TeamEventsMirror.serverCreatedAtMs),
                        \(Schema.TeamEventsMirror.eventTsMs),
                        \(Schema.TeamEventsMirror.receivedAtMs)
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "evt1", "wid2", "shex", Schema.ShareSources.gitCommits, "gh_commit_pushed",
                    "{}", 2_000, 1_990, 2_010
                ]
            )
        }

        // Duplicate (workspace_id, event_id) → rejected.
        XCTAssertThrowsError(
            try db.writeSQL { rawDB in
                try rawDB.execute(
                    sql: """
                        INSERT INTO \(Schema.TeamEventsMirror.tableName) (
                            \(Schema.TeamEventsMirror.eventID),
                            \(Schema.TeamEventsMirror.workspaceID),
                            \(Schema.TeamEventsMirror.senderPubkeyHex),
                            \(Schema.TeamEventsMirror.sourceKind),
                            \(Schema.TeamEventsMirror.kind),
                            \(Schema.TeamEventsMirror.plaintextPayloadJSON),
                            \(Schema.TeamEventsMirror.serverCreatedAtMs),
                            \(Schema.TeamEventsMirror.eventTsMs),
                            \(Schema.TeamEventsMirror.receivedAtMs)
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "evt1", "wid1" /* duplicate composite */, "shex",
                        Schema.ShareSources.gitCommits, "gh_commit_pushed",
                        "{}", 3_000, 2_990, 3_010
                    ]
                )
            }
        )

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.TeamEventsMirror.tableName)")
            XCTAssertEqual(count, 2)
        }
    }
}
