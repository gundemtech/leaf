// Track 5 / S7 C.10+C.11 — Reader Realtime extension coverage.
//
// Tests service-level absorbRealtimePush for both DM and TeamEvent services,
// plus MessagesMirrorStore.unreadInboundCountByWorkspace.
//
// The @MainActor DirectMessageInboxReader / TeamEventMirrorReader live in the Leaf
// app module (not LeafCore) and cannot be tested from LeafCoreTests directly.
// We test the *service* absorbRealtimePush methods + the new Store aggregate here
// instead — the reader wrappers are thin delegates that we verify via
// xcodebuild compile check.

import CryptoKit
import XCTest
import GRDB
@testable import LeafCore

// MARK: - MessagesMirrorStore.unreadInboundCountByWorkspace

final class UnreadDMCountByWorkspaceTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    private let ws1 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let ws2 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-unread-agg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try LeafCore.Database.openForWrite(
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
        workspaceID: String,
        direction: DirectMessageMirrorRow.Direction,
        readAtMs: Int64? = nil
    ) -> DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: messageID,
            workspaceID: workspaceID,
            senderPubkeyHex: String(repeating: "a", count: 64),
            senderMemberID: "sender-1",
            senderDisplayName: "Sender",
            recipientPubkeyHex: String(repeating: "b", count: 64),
            kind: .ping,
            body: "hello",
            attachment: nil,
            replyTo: nil,
            sentAtMs: 1_000_000,
            serverCreatedAtMs: 1_000_000,
            readAtMs: readAtMs,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: direction,
            lastSyncedAtMs: 1_000_000
        )
    }

    // 1. Empty DB → empty map
    func testUnreadCountByWorkspace_EmptyDB_EmptyMap() throws {
        let map = try db.readUnreadDMCountByWorkspace()
        XCTAssertTrue(map.isEmpty)
    }

    // 2. 3 unread inbound in ws1 + 1 in ws2 → correct counts
    func testUnreadCountByWorkspace_ThreeInWS1_OneInWS2() throws {
        for i in 1...3 {
            let r = makeRow(messageID: "ws1-\(i)", workspaceID: ws1, direction: .inbound)
            try db.writeSQL { try MessagesMirrorStore.upsert(r, in: $0) }
        }
        let r = makeRow(messageID: "ws2-1", workspaceID: ws2, direction: .inbound)
        try db.writeSQL { try MessagesMirrorStore.upsert(r, in: $0) }

        let map = try db.readUnreadDMCountByWorkspace()
        XCTAssertEqual(map[ws1], 3)
        XCTAssertEqual(map[ws2], 1)
    }

    // 3. Outbound rows excluded
    func testUnreadCountByWorkspace_OutboundExcluded() throws {
        let r = makeRow(messageID: "out-1", workspaceID: ws1, direction: .outbound)
        try db.writeSQL { try MessagesMirrorStore.upsert(r, in: $0) }

        let map = try db.readUnreadDMCountByWorkspace()
        XCTAssertNil(map[ws1], "outbound must not contribute to unread count")
    }

    // 4. Read DMs excluded (read_at_ms not null)
    func testUnreadCountByWorkspace_ReadDMsExcluded() throws {
        let unread = makeRow(messageID: "unread-1", workspaceID: ws1, direction: .inbound, readAtMs: nil)
        let read = makeRow(messageID: "read-1", workspaceID: ws1, direction: .inbound, readAtMs: 999_000)
        try db.writeSQL { try MessagesMirrorStore.upsert(unread, in: $0) }
        try db.writeSQL { try MessagesMirrorStore.upsert(read, in: $0) }

        let map = try db.readUnreadDMCountByWorkspace()
        XCTAssertEqual(map[ws1], 1, "read DMs must not be counted")
    }

    // 5. Single workspace — map has exactly one entry
    func testUnreadCountByWorkspace_SingleWorkspace() throws {
        for i in 1...5 {
            let r = makeRow(messageID: "m-\(i)", workspaceID: ws1, direction: .inbound)
            try db.writeSQL { try MessagesMirrorStore.upsert(r, in: $0) }
        }
        let map = try db.readUnreadDMCountByWorkspace()
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[ws1], 5)
    }
}

// MARK: - DirectMessageInboxService.absorbRealtimePush

final class DirectMessageInboxServiceAbsorbTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!

    private let workspaceID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    private let senderPubkey = String(repeating: "c", count: 64)
    private let recipientPubkey = String(repeating: "d", count: 64)

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-dm-absorb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try LeafCore.Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeService() -> DirectMessageInboxService {
        let captured = recipientPubkey
        return DirectMessageInboxService(
            database: db,
            supabase: SupabaseClient(
                baseURL: URL(string: "https://test.supabase.co")!,
                anonKey: "k",
                urlSession: URLSession(configuration: .ephemeral),
                identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
            ),
            codec: DummyDMCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore"),
            recipientPubkeyHex: { captured }
        )
    }

    private func makeRow(
        messageID: String,
        direction: DirectMessageMirrorRow.Direction = .inbound,
        readAtMs: Int64? = nil
    ) -> DirectMessageMirrorRow {
        DirectMessageMirrorRow(
            messageID: messageID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkey,
            senderMemberID: "smid",
            senderDisplayName: "Sender",
            recipientPubkeyHex: recipientPubkey,
            kind: .handoff,
            body: "test body",
            attachment: nil,
            replyTo: nil,
            sentAtMs: 2_000_000,
            serverCreatedAtMs: 2_000_000,
            readAtMs: readAtMs,
            doneAtMs: nil,
            doneByPubkeyHex: nil,
            direction: direction,
            lastSyncedAtMs: 2_000_000
        )
    }

    // 1. absorbRealtimePush UPSERTs the row into messages_mirror
    func testAbsorbRealtimePush_InsertsRow() throws {
        let svc = makeService()
        let row = makeRow(messageID: "rt-1")
        try svc.absorbRealtimePush(row)

        let fetched = try db.readSQL { try MessagesMirrorStore.read(messageID: "rt-1", in: $0) }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.body, "test body")
        XCTAssertEqual(fetched?.kind, .handoff)
    }

    // 2. Calling twice with the same messageID is idempotent — no duplicate rows
    func testAbsorbRealtimePush_Idempotent() throws {
        let svc = makeService()
        let row = makeRow(messageID: "rt-idemp-1")
        try svc.absorbRealtimePush(row)
        try svc.absorbRealtimePush(row)

        let count = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: """
                SELECT COUNT(*) FROM \(Schema.MessagesMirror.tableName)
                WHERE message_id = 'rt-idemp-1'
            """)
        }
        XCTAssertEqual(count, 1)
    }

    // 3. Inbound row contributes to unreadCountByWorkspace
    func testAbsorbRealtimePush_UpdatesUnreadAggregate() throws {
        let svc = makeService()
        let row = makeRow(messageID: "rt-unread-1", direction: .inbound)
        try svc.absorbRealtimePush(row)

        let map = try db.readUnreadDMCountByWorkspace()
        XCTAssertEqual(map[workspaceID], 1)
    }

    // 4. Row with readAtMs set does NOT appear in unread aggregate
    func testAbsorbRealtimePush_ReadRowNotInUnreadAggregate() throws {
        let svc = makeService()
        let row = makeRow(messageID: "rt-read-1", direction: .inbound, readAtMs: 1_000)
        try svc.absorbRealtimePush(row)

        let map = try db.readUnreadDMCountByWorkspace()
        XCTAssertNil(map[workspaceID], "read message must not appear in unread aggregate")
    }

    // 5. Multiple workspaces tracked correctly
    func testAbsorbRealtimePush_MultipleWorkspaceCounts() throws {
        let ws2 = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let svc = makeService()

        // 2 in workspaceID, 1 in ws2
        try svc.absorbRealtimePush(makeRow(messageID: "rt-a1"))
        try svc.absorbRealtimePush(makeRow(messageID: "rt-a2"))
        let row2 = DirectMessageMirrorRow(
            messageID: "rt-b1",
            workspaceID: ws2,
            senderPubkeyHex: senderPubkey,
            senderMemberID: "smid",
            senderDisplayName: "Sender",
            recipientPubkeyHex: recipientPubkey,
            kind: .ping,
            body: "ws2 msg",
            attachment: nil, replyTo: nil,
            sentAtMs: 2_000_000, serverCreatedAtMs: 2_000_000,
            readAtMs: nil, doneAtMs: nil, doneByPubkeyHex: nil,
            direction: .inbound, lastSyncedAtMs: 2_000_000
        )
        try svc.absorbRealtimePush(row2)

        let map = try db.readUnreadDMCountByWorkspace()
        XCTAssertEqual(map[workspaceID], 2)
        XCTAssertEqual(map[ws2], 1)
    }
}

// MARK: - TeamEventMirrorService.absorbRealtimePush

final class TeamEventMirrorServiceAbsorbTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!
    private let workspaceID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    private let senderPubkey = String(repeating: "e", count: 64)

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-team-event-absorb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try LeafCore.Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeService() -> TeamEventMirrorService {
        TeamEventMirrorService(
            database: db,
            supabase: SupabaseClient(
                baseURL: URL(string: "https://test.supabase.co")!,
                anonKey: "k",
                urlSession: URLSession(configuration: .ephemeral),
                identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x02, count: 32)) }
            ),
            codec: UnimplementedTeamEventBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore")
        )
    }

    private func makeRow(
        eventID: String = "evt-1",
        workspaceID: String? = nil,
        senderPubkeyHex: String? = nil
    ) -> TeamEventMirrorRow {
        TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: workspaceID ?? self.workspaceID,
            senderPubkeyHex: senderPubkeyHex ?? self.senderPubkey,
            source: .gitCommits,
            kind: "gh_commit_pushed",
            plaintextPayloadJSON: "{\"fields\":{\"commit_message\":\"fix bug\"}}",
            serverCreatedAtMs: 3_000_000,
            eventTsMs: 2_999_000,
            receivedAtMs: 3_001_000
        )
    }

    // 1. absorbRealtimePush inserts row
    func testAbsorbRealtimePush_InsertsRow() async throws {
        let svc = makeService()
        let row = makeRow(eventID: "rte-1")
        try await svc.absorbRealtimePush(row)

        let count = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: """
                SELECT COUNT(*) FROM \(Schema.TeamEventsMirror.tableName)
                WHERE event_id = 'rte-1'
            """)
        }
        XCTAssertEqual(count, 1)
    }

    // 2. Calling twice with same (workspaceID, eventID) is idempotent
    func testAbsorbRealtimePush_Idempotent() async throws {
        let svc = makeService()
        let row = makeRow(eventID: "rte-idemp-1")
        try await svc.absorbRealtimePush(row)
        try await svc.absorbRealtimePush(row)

        let count = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: """
                SELECT COUNT(*) FROM \(Schema.TeamEventsMirror.tableName)
            """)
        }
        XCTAssertEqual(count, 1)
    }

    // 3. Second write with same eventID updates receivedAtMs (ON CONFLICT DO UPDATE)
    func testAbsorbRealtimePush_UpdatesReceivedAtMs() async throws {
        let svc = makeService()
        let row1 = makeRow(eventID: "rte-update-1")
        let row2 = TeamEventMirrorRow(
            eventID: "rte-update-1",
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkey,
            source: .gitCommits,
            kind: "gh_commit_pushed",
            plaintextPayloadJSON: "{\"fields\":{\"commit_message\":\"fix bug v2\"}}",
            serverCreatedAtMs: 3_000_000,
            eventTsMs: 2_999_000,
            receivedAtMs: 9_999_999  // updated value
        )
        try await svc.absorbRealtimePush(row1)
        try await svc.absorbRealtimePush(row2)

        let recent = try db.readSQL { rawDB in
            try TeamEventMirrorStore.readRecent(workspaceID: self.workspaceID, limit: 10, in: rawDB)
        }
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].receivedAtMs, 9_999_999)
    }

    // 4. Different (workspaceID, eventID) pairs create separate rows
    func testAbsorbRealtimePush_DifferentWorkspaces_TwoRows() async throws {
        let ws2 = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let svc = makeService()
        let row1 = makeRow(eventID: "rte-shared-1", workspaceID: workspaceID)
        let row2 = makeRow(eventID: "rte-shared-1", workspaceID: ws2)

        try await svc.absorbRealtimePush(row1)
        try await svc.absorbRealtimePush(row2)

        let count = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT COUNT(*) FROM \(Schema.TeamEventsMirror.tableName)")
        }
        XCTAssertEqual(count, 2, "Same eventID in different workspaces = distinct composite PKs")
    }

    // 5. absorbRealtimePush does not throw on a valid row
    func testAbsorbRealtimePush_DoesNotThrow() async {
        let svc = makeService()
        let row = makeRow(eventID: "rte-nothrow")
        do {
            try await svc.absorbRealtimePush(row)
        } catch {
            XCTFail("absorbRealtimePush threw unexpectedly: \(error)")
        }
    }
}

// MARK: - Dummy codec for DM inbox service tests

private struct DummyDMCodec: DirectMessageBlobCodec {
    func encode(_ plaintext: DirectMessagePlaintext, keyID: Data, teamKey: Data) throws -> Data {
        Data()
    }
    func decode(_ bytes: Data, teamKey: Data) throws -> DirectMessagePlaintext {
        throw LeafError.directMessageBlobMalformed
    }
}
