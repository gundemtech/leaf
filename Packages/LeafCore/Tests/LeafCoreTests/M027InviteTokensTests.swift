// M027 — Invite System Redesign migration schema check.
// Covers invite_tokens table + workspaces defaults columns + indices + CHECK constraints.

import XCTest
import GRDB
@testable import LeafCore

final class M027InviteTokensTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m027-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM027_InviteTokensTableExistsWithExpectedColumns() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            // Table exists.
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.InviteTokens.tableName]
            )
            XCTAssertEqual(tables, [Schema.InviteTokens.tableName])

            // Columns set.
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.InviteTokens.tableName))"
            )
            let columnNames = Set(columns.compactMap { $0["name"] as String? })
            XCTAssertEqual(columnNames, Set([
                Schema.InviteTokens.code,
                Schema.InviteTokens.workspaceID,
                Schema.InviteTokens.createdByPubkey,
                Schema.InviteTokens.label,
                Schema.InviteTokens.ttlSeconds,
                Schema.InviteTokens.expiresAtMs,
                Schema.InviteTokens.maxUses,
                Schema.InviteTokens.usedCount,
                Schema.InviteTokens.deletedAtMs,
                Schema.InviteTokens.createdAtMs
            ]))

            // Partial index exists.
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
                arguments: [Schema.InviteTokens.indexWorkspaceActive]
            )
            XCTAssertEqual(indexes, [Schema.InviteTokens.indexWorkspaceActive])
        }
    }

    func testM027_InviteTokensCodeFormatCheck_AcceptsValid_RejectsInvalid() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            // Seed a workspace row (id is TEXT in local schema, distinct from Supabase uuid).
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.Workspaces.tableName)
                    (\(Schema.Workspaces.id), \(Schema.Workspaces.name), \(Schema.Workspaces.createdAtMs),
                     \(Schema.Workspaces.createdByMemberID))
                VALUES ('w1', 'TestRoom', 1700000000000, 'm1')
                """)

            // Valid format passes CHECK.
            XCTAssertNoThrow(try rawDB.execute(sql: """
                INSERT INTO \(Schema.InviteTokens.tableName)
                    (\(Schema.InviteTokens.code), \(Schema.InviteTokens.workspaceID),
                     \(Schema.InviteTokens.createdByPubkey), \(Schema.InviteTokens.ttlSeconds),
                     \(Schema.InviteTokens.expiresAtMs), \(Schema.InviteTokens.createdAtMs))
                VALUES ('LEAF-A8X7-B3K9-Q2N4', 'w1', 'aa11', 86400, 1700086400000, 1700000000000)
                """))

            // Malformed (wrong length / missing prefix) — CHECK rejects.
            XCTAssertThrowsError(try rawDB.execute(sql: """
                INSERT INTO \(Schema.InviteTokens.tableName)
                    (\(Schema.InviteTokens.code), \(Schema.InviteTokens.workspaceID),
                     \(Schema.InviteTokens.createdByPubkey), \(Schema.InviteTokens.ttlSeconds),
                     \(Schema.InviteTokens.expiresAtMs), \(Schema.InviteTokens.createdAtMs))
                VALUES ('GARBAGE', 'w1', 'aa11', 86400, 1700086400000, 1700000000000)
                """))

            // Excluded alphabet ('1' / 'O' / 'L') rejected.
            XCTAssertThrowsError(try rawDB.execute(sql: """
                INSERT INTO \(Schema.InviteTokens.tableName)
                    (\(Schema.InviteTokens.code), \(Schema.InviteTokens.workspaceID),
                     \(Schema.InviteTokens.createdByPubkey), \(Schema.InviteTokens.ttlSeconds),
                     \(Schema.InviteTokens.expiresAtMs), \(Schema.InviteTokens.createdAtMs))
                VALUES ('LEAF-1234-5678-90AB', 'w1', 'aa11', 86400, 1700086400000, 1700000000000)
                """))

            XCTAssertThrowsError(try rawDB.execute(sql: """
                INSERT INTO \(Schema.InviteTokens.tableName)
                    (\(Schema.InviteTokens.code), \(Schema.InviteTokens.workspaceID),
                     \(Schema.InviteTokens.createdByPubkey), \(Schema.InviteTokens.ttlSeconds),
                     \(Schema.InviteTokens.expiresAtMs), \(Schema.InviteTokens.createdAtMs))
                VALUES ('LEAF-LOOK-OUT2-ABCD', 'w1', 'aa11', 86400, 1700086400000, 1700000000000)
                """))
        }
    }

    func testM027_InviteTokensMaxUsesPositive_CHECK_Constraint() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.Workspaces.tableName)
                    (\(Schema.Workspaces.id), \(Schema.Workspaces.name), \(Schema.Workspaces.createdAtMs),
                     \(Schema.Workspaces.createdByMemberID))
                VALUES ('w1', 'TestRoom', 1700000000000, 'm1')
                """)

            // max_uses = 0 rejected by CHECK.
            XCTAssertThrowsError(try rawDB.execute(sql: """
                INSERT INTO \(Schema.InviteTokens.tableName)
                    (\(Schema.InviteTokens.code), \(Schema.InviteTokens.workspaceID),
                     \(Schema.InviteTokens.createdByPubkey), \(Schema.InviteTokens.ttlSeconds),
                     \(Schema.InviteTokens.expiresAtMs), \(Schema.InviteTokens.maxUses),
                     \(Schema.InviteTokens.createdAtMs))
                VALUES ('LEAF-K5J2-M8N3-W7K4', 'w1', 'aa11', 86400, 1700086400000, 0, 1700000000000)
                """))

            // max_uses = 1 accepted.
            XCTAssertNoThrow(try rawDB.execute(sql: """
                INSERT INTO \(Schema.InviteTokens.tableName)
                    (\(Schema.InviteTokens.code), \(Schema.InviteTokens.workspaceID),
                     \(Schema.InviteTokens.createdByPubkey), \(Schema.InviteTokens.ttlSeconds),
                     \(Schema.InviteTokens.expiresAtMs), \(Schema.InviteTokens.maxUses),
                     \(Schema.InviteTokens.createdAtMs))
                VALUES ('LEAF-T5K2-MJN3-WSK4', 'w1', 'aa11', 86400, 1700086400000, 1, 1700000000000)
                """))

            // max_uses = NULL (unlimited) accepted.
            XCTAssertNoThrow(try rawDB.execute(sql: """
                INSERT INTO \(Schema.InviteTokens.tableName)
                    (\(Schema.InviteTokens.code), \(Schema.InviteTokens.workspaceID),
                     \(Schema.InviteTokens.createdByPubkey), \(Schema.InviteTokens.ttlSeconds),
                     \(Schema.InviteTokens.expiresAtMs), \(Schema.InviteTokens.createdAtMs))
                VALUES ('LEAF-VWXY-Z234-5678', 'w1', 'aa11', 86400, 1700086400000, 1700000000000)
                """))
        }
    }

    func testM027_WorkspacesDefaultsColumnsAndValues() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.writeSQL { rawDB in
            try rawDB.execute(sql: """
                INSERT INTO \(Schema.Workspaces.tableName)
                    (\(Schema.Workspaces.id), \(Schema.Workspaces.name), \(Schema.Workspaces.createdAtMs),
                     \(Schema.Workspaces.createdByMemberID))
                VALUES ('w2', 'Defaults', 1700000000000, 'm2')
                """)
        }

        try db.readSQL { rawDB in
            // Both new columns present.
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.Workspaces.tableName))"
            )
            let columnNames = Set(columns.compactMap { $0["name"] as String? })
            XCTAssertTrue(columnNames.contains(Schema.Workspaces.defaultInviteTtlSeconds))
            XCTAssertTrue(columnNames.contains(Schema.Workspaces.defaultSingleUse))

            // Defaults applied.
            let ttl = try Int.fetchOne(
                rawDB,
                sql: "SELECT \(Schema.Workspaces.defaultInviteTtlSeconds) FROM \(Schema.Workspaces.tableName) WHERE \(Schema.Workspaces.id) = 'w2'"
            )
            XCTAssertEqual(ttl, 86400)

            let singleUse = try Int.fetchOne(
                rawDB,
                sql: "SELECT \(Schema.Workspaces.defaultSingleUse) FROM \(Schema.Workspaces.tableName) WHERE \(Schema.Workspaces.id) = 'w2'"
            )
            XCTAssertEqual(singleUse, 0)
        }
    }
}
