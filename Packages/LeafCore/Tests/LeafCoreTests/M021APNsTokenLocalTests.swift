// Phase Track-5 S4 — M021 `apns_token_local` schema check.

import XCTest
import GRDB
@testable import LeafCore

final class M021APNsTokenLocalTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m021-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM021_CreatesTable() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.APNsTokenLocal.tableName]
            )
            XCTAssertEqual(tables, [Schema.APNsTokenLocal.tableName])

            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.APNsTokenLocal.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.APNsTokenLocal.deviceID,
                    Schema.APNsTokenLocal.apnsToken,
                    Schema.APNsTokenLocal.environment,
                    Schema.APNsTokenLocal.registeredAtMs,
                    Schema.APNsTokenLocal.lastPushedAtMs,
                    Schema.APNsTokenLocal.serverSyncedAtMs
                ])
            )

            // PK on device_id.
            let pk = try XCTUnwrap(byName[Schema.APNsTokenLocal.deviceID])
            XCTAssertEqual(pk["pk"] as Int?, 1)
            XCTAssertEqual(pk["notnull"] as Int?, 1)

            // NOT NULL columns.
            for col in [
                Schema.APNsTokenLocal.apnsToken,
                Schema.APNsTokenLocal.environment,
                Schema.APNsTokenLocal.registeredAtMs
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) should be NOT NULL")
            }
            for col in [
                Schema.APNsTokenLocal.lastPushedAtMs,
                Schema.APNsTokenLocal.serverSyncedAtMs
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 0, "column \(col) should be nullable")
            }
        }
    }

    func testM021_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM021_EnvironmentCheckConstraintRejectsUnknown() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertThrowsError(
            try db.writeSQL { rawDB in
                try rawDB.execute(
                    sql: """
                        INSERT INTO \(Schema.APNsTokenLocal.tableName) (
                            \(Schema.APNsTokenLocal.deviceID),
                            \(Schema.APNsTokenLocal.apnsToken),
                            \(Schema.APNsTokenLocal.environment),
                            \(Schema.APNsTokenLocal.registeredAtMs)
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: ["d1", "tok", "staging" /* invalid */, 1_000]
                )
            }
        ) { error in
            XCTAssertTrue(String(describing: error).contains("CHECK"))
        }
    }
}
