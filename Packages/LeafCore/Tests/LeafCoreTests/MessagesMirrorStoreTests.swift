// Phase Track-5 S4 — MessagesMirrorStore CRUD coverage.

import XCTest
import GRDB
@testable import LeafCore

final class MessagesMirrorStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-mmstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRow(
        messageID: String,
        workspaceID: String = "w1",
        recipientPubkeyHex: String = "r1",
        senderPubkeyHex: String = "s1",
        kind: DirectMessageKind = .ping,
        body: String = "hello",
        direction: DirectMessageMirrorRow.Direction = .inbound,
        serverCreatedAtMs: Int64 = 1_000,
        readAtMs: Int64? = nil,
        doneAtMs: Int64? = nil
    ) -> DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: messageID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkeyHex,
            senderMemberID: "m\(senderPubkeyHex)",
            senderDisplayName: "Sender",
            recipientPubkeyHex: recipientPubkeyHex,
            kind: kind,
            body: body,
            attachment: nil,
            replyTo: nil,
            sentAtMs: serverCreatedAtMs - 50,
            serverCreatedAtMs: serverCreatedAtMs,
            readAtMs: readAtMs,
            doneAtMs: doneAtMs,
            doneByPubkeyHex: nil,
            direction: direction,
            lastSyncedAtMs: serverCreatedAtMs
        )
    }

    func testUpsertIdempotent_SameRowTwice_SingleEntry() throws {
        let row = makeRow(messageID: "m1")
        try db.writeSQL { rawDB in
            try MessagesMirrorStore.upsert(row, in: rawDB)
            try MessagesMirrorStore.upsert(row, in: rawDB)
        }

        try db.readSQL { rawDB in
            let count = try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.MessagesMirror.tableName)")
            XCTAssertEqual(count, 1)
        }
    }

    func testReadByMessageID_ReturnsRow() throws {
        let row = makeRow(messageID: "m1", body: "ping body")
        try db.writeSQL { try MessagesMirrorStore.upsert(row, in: $0) }

        let fetched = try db.readSQL { try MessagesMirrorStore.read(messageID: "m1", in: $0) }
        XCTAssertEqual(fetched?.messageID, "m1")
        XCTAssertEqual(fetched?.body, "ping body")
        XCTAssertEqual(fetched?.kind, .ping)
        XCTAssertEqual(fetched?.direction, .inbound)
    }

    func testReadByMessageID_MissingReturnsNil() throws {
        let fetched = try db.readSQL { try MessagesMirrorStore.read(messageID: "missing", in: $0) }
        XCTAssertNil(fetched)
    }

    func testReadRecent_OrderedByServerCreatedDesc() throws {
        let rows = [
            makeRow(messageID: "m1", serverCreatedAtMs: 1_000),
            makeRow(messageID: "m2", serverCreatedAtMs: 3_000),
            makeRow(messageID: "m3", serverCreatedAtMs: 2_000)
        ]
        try db.writeSQL { rawDB in
            for r in rows { try MessagesMirrorStore.upsert(r, in: rawDB) }
        }

        let fetched = try db.readSQL {
            try MessagesMirrorStore.readRecent(workspaceID: "w1", in: $0)
        }
        XCTAssertEqual(fetched.map { $0.messageID }, ["m2", "m3", "m1"])
    }

    func testReadUnreadInbound_FiltersOutReadAndOutbound() throws {
        try db.writeSQL { rawDB in
            try MessagesMirrorStore.upsert(makeRow(messageID: "unread-1"), in: rawDB)
            try MessagesMirrorStore.upsert(
                makeRow(messageID: "read-1", readAtMs: 5_000), in: rawDB
            )
            try MessagesMirrorStore.upsert(
                makeRow(messageID: "outbound-1", direction: .outbound), in: rawDB
            )
        }

        let unread = try db.readSQL {
            try MessagesMirrorStore.readUnreadInbound(
                workspaceID: "w1", recipientPubkeyHex: "r1", in: $0
            )
        }
        XCTAssertEqual(unread.map { $0.messageID }, ["unread-1"])
    }

    func testMaxServerCreatedAtMs_BothDirectionsTracked() throws {
        try db.writeSQL { rawDB in
            try MessagesMirrorStore.upsert(
                makeRow(messageID: "in-1", direction: .inbound, serverCreatedAtMs: 1_000),
                in: rawDB
            )
            try MessagesMirrorStore.upsert(
                makeRow(messageID: "in-2", direction: .inbound, serverCreatedAtMs: 2_000),
                in: rawDB
            )
            try MessagesMirrorStore.upsert(
                makeRow(messageID: "out-1", direction: .outbound, serverCreatedAtMs: 5_000),
                in: rawDB
            )
        }

        try db.readSQL { rawDB in
            let inMax = try MessagesMirrorStore.maxServerCreatedAtMs(
                workspaceID: "w1", direction: .inbound, in: rawDB
            )
            XCTAssertEqual(inMax, 2_000)

            let outMax = try MessagesMirrorStore.maxServerCreatedAtMs(
                workspaceID: "w1", direction: .outbound, in: rawDB
            )
            XCTAssertEqual(outMax, 5_000)
        }
    }

    func testMaxServerCreatedAtMs_EmptyTableReturnsNil() throws {
        try db.readSQL { rawDB in
            let max = try MessagesMirrorStore.maxServerCreatedAtMs(
                workspaceID: "w1", direction: .inbound, in: rawDB
            )
            XCTAssertNil(max)
        }
    }

    func testMarkRead_UpdatesReadAt() throws {
        try db.writeSQL { rawDB in
            try MessagesMirrorStore.upsert(makeRow(messageID: "m1"), in: rawDB)
            try MessagesMirrorStore.markRead(messageID: "m1", atMs: 9_000, in: rawDB)
        }

        let fetched = try db.readSQL { try MessagesMirrorStore.read(messageID: "m1", in: $0) }
        XCTAssertEqual(fetched?.readAtMs, 9_000)
        XCTAssertEqual(fetched?.lastSyncedAtMs, 9_000)
    }

    func testMarkDone_UpdatesDoneAtAndDoneByPubkey() throws {
        try db.writeSQL { rawDB in
            try MessagesMirrorStore.upsert(
                makeRow(messageID: "task-1", kind: .task), in: rawDB
            )
            try MessagesMirrorStore.markDone(
                messageID: "task-1", atMs: 9_500, doneByPubkeyHex: "doneby", in: rawDB
            )
        }

        let fetched = try db.readSQL { try MessagesMirrorStore.read(messageID: "task-1", in: $0) }
        XCTAssertEqual(fetched?.doneAtMs, 9_500)
        XCTAssertEqual(fetched?.doneByPubkeyHex, "doneby")
    }

    func testUpsertWithAttachment_RoundTripsAttachmentFields() throws {
        let row = DirectMessageMirrorRow(
            messageID: "att-1",
            workspaceID: "w1",
            senderPubkeyHex: "s1",
            senderMemberID: "ms1",
            senderDisplayName: "Sender",
            recipientPubkeyHex: "r1",
            kind: .handoff,
            body: "see PR",
            attachment: DirectMessageAttachment(
                kind: "github_pr", externalRef: "PR #142", displayLabel: nil
            ),
            replyTo: nil,
            sentAtMs: 1_000,
            serverCreatedAtMs: 1_050,
            readAtMs: nil,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: .outbound,
            lastSyncedAtMs: 1_050
        )

        try db.writeSQL { try MessagesMirrorStore.upsert(row, in: $0) }

        let fetched = try db.readSQL { try MessagesMirrorStore.read(messageID: "att-1", in: $0) }
        XCTAssertEqual(fetched?.attachment?.kind, "github_pr")
        XCTAssertEqual(fetched?.attachment?.externalRef, "PR #142")
    }
}
