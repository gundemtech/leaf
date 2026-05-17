// Phase 5.5.A — M010 `pending_invites` table + idx_pending_invites_status index.

import GRDB
import XCTest

@testable import LeafCore

final class M010PendingInvitesTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m010-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM010_CreatesTableAndIndex() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            // Table exists.
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.PendingInvites.tableName]
            )
            XCTAssertEqual(tables, [Schema.PendingInvites.tableName])

            // Columns present, with correct nullability + PK on token.
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.PendingInvites.tableName))"
            )
            let byName = Dictionary(
                uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                    guard let name = row["name"] as String? else { return nil }
                    return (name, row)
                })

            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.PendingInvites.token,
                    Schema.PendingInvites.otp,
                    Schema.PendingInvites.inviteePubkeyHex,
                    Schema.PendingInvites.inviteeDisplayNameHint,
                    Schema.PendingInvites.createdAtMs,
                    Schema.PendingInvites.expiresAtMs,
                    Schema.PendingInvites.status,
                    Schema.PendingInvites.lastPolledAtMs,
                ])
            )

            let token = try XCTUnwrap(byName[Schema.PendingInvites.token])
            XCTAssertEqual(token["pk"] as Int?, 1)
            XCTAssertEqual(token["notnull"] as Int?, 1)

            for col in [
                Schema.PendingInvites.otp,
                Schema.PendingInvites.inviteePubkeyHex,
                Schema.PendingInvites.createdAtMs,
                Schema.PendingInvites.expiresAtMs,
                Schema.PendingInvites.status,
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) should be NOT NULL")
            }
            for col in [
                Schema.PendingInvites.inviteeDisplayNameHint,
                Schema.PendingInvites.lastPolledAtMs,
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 0, "column \(col) should be nullable")
            }

            // Index exists.
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.PendingInvites.tableName]
            )
            XCTAssertTrue(
                indexes.contains(Schema.PendingInvites.indexStatus),
                "expected index \(Schema.PendingInvites.indexStatus); found \(indexes)"
            )
        }
    }

    func testM010_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM010_TableEmptyAfterFreshMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.PendingInvites.tableName)")
            XCTAssertEqual(count, 0)
        }
    }
}
