// Phase Track-5 S5 — M024 `team_event_broadcast_offsets` schema check.

import XCTest
import GRDB
@testable import LeafCore

final class M024TeamEventBroadcastOffsetsTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m024-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM024_CreatesTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.TeamEventBroadcastOffsets.tableName]
            )
            XCTAssertEqual(tables, [Schema.TeamEventBroadcastOffsets.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.TeamEventBroadcastOffsets.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.TeamEventBroadcastOffsets.workspaceID,
                    Schema.TeamEventBroadcastOffsets.cursorEventID,
                    Schema.TeamEventBroadcastOffsets.lastAttemptAtMs,
                    Schema.TeamEventBroadcastOffsets.lastSuccessAtMs,
                    Schema.TeamEventBroadcastOffsets.consecutiveFailures
                ])
            )

            // PK on workspace_id.
            let pk = try XCTUnwrap(byName[Schema.TeamEventBroadcastOffsets.workspaceID])
            XCTAssertEqual(pk["pk"] as Int?, 1)
            XCTAssertEqual(pk["notnull"] as Int?, 1)

            // NOT NULL on cursor_event_id + consecutive_failures.
            let cursorRow = try XCTUnwrap(byName[Schema.TeamEventBroadcastOffsets.cursorEventID])
            XCTAssertEqual(cursorRow["notnull"] as Int?, 1)
            let failsRow = try XCTUnwrap(byName[Schema.TeamEventBroadcastOffsets.consecutiveFailures])
            XCTAssertEqual(failsRow["notnull"] as Int?, 1)

            // Nullable timestamps.
            let lastAttempt = try XCTUnwrap(byName[Schema.TeamEventBroadcastOffsets.lastAttemptAtMs])
            XCTAssertEqual(lastAttempt["notnull"] as Int?, 0)
            let lastSuccess = try XCTUnwrap(byName[Schema.TeamEventBroadcastOffsets.lastSuccessAtMs])
            XCTAssertEqual(lastSuccess["notnull"] as Int?, 0)
        }
    }

    func testM024_DefaultsCursorEventIDAndConsecutiveFailures() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "INSERT INTO \(Schema.TeamEventBroadcastOffsets.tableName) (\(Schema.TeamEventBroadcastOffsets.workspaceID)) VALUES (?)",
                arguments: ["wid-defaults"]
            )
        }

        try db.readSQL { rawDB in
            let cursor = try Int.fetchOne(
                rawDB,
                sql: "SELECT \(Schema.TeamEventBroadcastOffsets.cursorEventID) FROM \(Schema.TeamEventBroadcastOffsets.tableName) WHERE \(Schema.TeamEventBroadcastOffsets.workspaceID) = ?",
                arguments: ["wid-defaults"]
            )
            XCTAssertEqual(cursor, 0)

            let fails = try Int.fetchOne(
                rawDB,
                sql: "SELECT \(Schema.TeamEventBroadcastOffsets.consecutiveFailures) FROM \(Schema.TeamEventBroadcastOffsets.tableName) WHERE \(Schema.TeamEventBroadcastOffsets.workspaceID) = ?",
                arguments: ["wid-defaults"]
            )
            XCTAssertEqual(fails, 0)
        }
    }

    func testM024_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM024_RejectsDuplicateWorkspacePrimaryKey() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "INSERT INTO \(Schema.TeamEventBroadcastOffsets.tableName) (\(Schema.TeamEventBroadcastOffsets.workspaceID)) VALUES (?)",
                arguments: ["wid-pk"]
            )
        }
        XCTAssertThrowsError(
            try db.writeSQL { rawDB in
                try rawDB.execute(
                    sql: "INSERT INTO \(Schema.TeamEventBroadcastOffsets.tableName) (\(Schema.TeamEventBroadcastOffsets.workspaceID)) VALUES (?)",
                    arguments: ["wid-pk"]
                )
            }
        )
    }
}
