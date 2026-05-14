// Phase Track-5 S4 — M020 `messages_mirror` schema check.

import XCTest
import GRDB
@testable import LeafCore

final class M020MessagesMirrorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-m020-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testM020_CreatesTableAndIndexes() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            // Table exists.
            let tables = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                arguments: [Schema.MessagesMirror.tableName]
            )
            XCTAssertEqual(tables, [Schema.MessagesMirror.tableName])

            // Columns + nullability + PK.
            let columns = try Row.fetchAll(
                rawDB,
                sql: "PRAGMA table_info(\(Schema.MessagesMirror.tableName))"
            )
            let byName = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Row)? in
                guard let name = row["name"] as String? else { return nil }
                return (name, row)
            })

            XCTAssertEqual(
                Set(byName.keys),
                Set([
                    Schema.MessagesMirror.messageID,
                    Schema.MessagesMirror.workspaceID,
                    Schema.MessagesMirror.senderPubkeyHex,
                    Schema.MessagesMirror.senderMemberID,
                    Schema.MessagesMirror.senderDisplayName,
                    Schema.MessagesMirror.recipientPubkeyHex,
                    Schema.MessagesMirror.kind,
                    Schema.MessagesMirror.body,
                    Schema.MessagesMirror.attachmentKind,
                    Schema.MessagesMirror.attachmentExternalRef,
                    Schema.MessagesMirror.replyTo,
                    Schema.MessagesMirror.sentAtMs,
                    Schema.MessagesMirror.serverCreatedAtMs,
                    Schema.MessagesMirror.readAtMs,
                    Schema.MessagesMirror.doneAtMs,
                    Schema.MessagesMirror.doneByPubkeyHex,
                    Schema.MessagesMirror.direction,
                    Schema.MessagesMirror.lastSyncedAtMs
                ])
            )

            // PK on message_id.
            let pk = try XCTUnwrap(byName[Schema.MessagesMirror.messageID])
            XCTAssertEqual(pk["pk"] as Int?, 1)
            XCTAssertEqual(pk["notnull"] as Int?, 1)

            // NOT NULL columns.
            for col in [
                Schema.MessagesMirror.workspaceID,
                Schema.MessagesMirror.senderPubkeyHex,
                Schema.MessagesMirror.senderMemberID,
                Schema.MessagesMirror.senderDisplayName,
                Schema.MessagesMirror.recipientPubkeyHex,
                Schema.MessagesMirror.kind,
                Schema.MessagesMirror.body,
                Schema.MessagesMirror.sentAtMs,
                Schema.MessagesMirror.serverCreatedAtMs,
                Schema.MessagesMirror.direction,
                Schema.MessagesMirror.lastSyncedAtMs
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 1, "column \(col) should be NOT NULL")
            }
            // Nullable columns.
            for col in [
                Schema.MessagesMirror.attachmentKind,
                Schema.MessagesMirror.attachmentExternalRef,
                Schema.MessagesMirror.replyTo,
                Schema.MessagesMirror.readAtMs,
                Schema.MessagesMirror.doneAtMs,
                Schema.MessagesMirror.doneByPubkeyHex
            ] {
                let row = try XCTUnwrap(byName[col])
                XCTAssertEqual(row["notnull"] as Int?, 0, "column \(col) should be nullable")
            }

            // Indexes — all three present.
            let indexes = try String.fetchAll(
                rawDB,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
                arguments: [Schema.MessagesMirror.tableName]
            )
            for idx in [
                Schema.MessagesMirror.indexWorkspaceRecent,
                Schema.MessagesMirror.indexUnread,
                Schema.MessagesMirror.indexOpenTasks
            ] {
                XCTAssertTrue(
                    indexes.contains(idx),
                    "expected index \(idx); found \(indexes)"
                )
            }
        }
    }

    func testM020_IsIdempotentOnReopen() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        _ = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    func testM020_TableEmptyAfterFreshMigration() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.MessagesMirror.tableName)")
            XCTAssertEqual(count, 0)
        }
    }

    func testM020_KindCheckConstraintRejectsUnknown() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertThrowsError(
            try db.writeSQL { rawDB in
                try rawDB.execute(
                    sql: """
                        INSERT INTO \(Schema.MessagesMirror.tableName) (
                            \(Schema.MessagesMirror.messageID),
                            \(Schema.MessagesMirror.workspaceID),
                            \(Schema.MessagesMirror.senderPubkeyHex),
                            \(Schema.MessagesMirror.senderMemberID),
                            \(Schema.MessagesMirror.senderDisplayName),
                            \(Schema.MessagesMirror.recipientPubkeyHex),
                            \(Schema.MessagesMirror.kind),
                            \(Schema.MessagesMirror.body),
                            \(Schema.MessagesMirror.sentAtMs),
                            \(Schema.MessagesMirror.serverCreatedAtMs),
                            \(Schema.MessagesMirror.direction),
                            \(Schema.MessagesMirror.lastSyncedAtMs)
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "m1", "wid", "shex", "smid", "Sender",
                        "rhex", "shout" /* invalid kind */, "body",
                        1_000, 2_000, "inbound", 2_000
                    ]
                )
            }
        ) { error in
            // CHECK constraint violation
            XCTAssertTrue(String(describing: error).contains("CHECK"))
        }
    }

    func testM020_DirectionCheckConstraintRejectsUnknown() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertThrowsError(
            try db.writeSQL { rawDB in
                try rawDB.execute(
                    sql: """
                        INSERT INTO \(Schema.MessagesMirror.tableName) (
                            \(Schema.MessagesMirror.messageID),
                            \(Schema.MessagesMirror.workspaceID),
                            \(Schema.MessagesMirror.senderPubkeyHex),
                            \(Schema.MessagesMirror.senderMemberID),
                            \(Schema.MessagesMirror.senderDisplayName),
                            \(Schema.MessagesMirror.recipientPubkeyHex),
                            \(Schema.MessagesMirror.kind),
                            \(Schema.MessagesMirror.body),
                            \(Schema.MessagesMirror.sentAtMs),
                            \(Schema.MessagesMirror.serverCreatedAtMs),
                            \(Schema.MessagesMirror.direction),
                            \(Schema.MessagesMirror.lastSyncedAtMs)
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        "m1", "wid", "shex", "smid", "Sender",
                        "rhex", "ping", "body",
                        1_000, 2_000, "sideways" /* invalid */, 2_000
                    ]
                )
            }
        ) { error in
            XCTAssertTrue(String(describing: error).contains("CHECK"))
        }
    }
}
