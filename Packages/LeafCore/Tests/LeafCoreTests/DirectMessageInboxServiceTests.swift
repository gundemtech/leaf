// Phase Track-5 S4 — DirectMessageInboxService recipient poll/decrypt/upsert coverage.
// C5 fix from Stage 6 review.

import XCTest
import CryptoKit
@testable import LeafCore

final class DirectMessageInboxServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!
    private let workspaceID = "11111111-1111-1111-1111-111111111111"
    private let teamKeyID = "22222222-2222-2222-2222-222222222222"
    private let selfPubkey = String(repeating: "a", count: 64)
    private let senderPubkey = String(repeating: "b", count: 64)
    private var teamKeyBytes: Data!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-inbox-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try LeafCore.Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
        teamKeyBytes = Data(repeating: 0xCC, count: 32)
        let keystoreRoot = tempDir.appendingPathComponent("keystore")
        try FileManager.default.createDirectory(at: keystoreRoot, withIntermediateDirectories: true)
        try TeamKeystore.writeTeamKey(teamKeyBytes,
                                       workspaceID: workspaceID,
                                       keyID: teamKeyID,
                                       at: keystoreRoot)
    }

    override func tearDown() async throws {
        db = nil
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeURLSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeJWT(pubkey: String) -> String {
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    /// Build a valid TestDirectMessageBlobCodec envelope for a given plaintext.
    /// Mirrors the codec used in DirectMessageServiceTests.
    private func makeEnvelope(plaintext: DirectMessagePlaintext) throws -> Data {
        let codec = InboxTestCodec()
        let keyID = Data(uuidStringToRawBytes(teamKeyID))
        return try codec.encode(plaintext, keyID: keyID, teamKey: teamKeyBytes)
    }

    private func uuidStringToRawBytes(_ s: String) -> [UInt8] {
        guard let uuid = UUID(uuidString: s) else { return Array(repeating: 0, count: 16) }
        return withUnsafeBytes(of: uuid.uuid) { Array($0) }
    }

    private func makeSession() -> SupabaseClient {
        SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
    }

    private func makeInboxService(supabase: SupabaseClient) -> DirectMessageInboxService {
        let captured = selfPubkey
        return DirectMessageInboxService(
            database: db,
            supabase: supabase,
            codec: InboxTestCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore"),
            recipientPubkeyHex: { captured }
        )
    }

    /// Helper — full bootstrap handler.
    private func wrapWithBootstrap(
        pubkey: String,
        dm: @escaping @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)
    ) -> @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data) {
        let jwt = makeJWT(pubkey: pubkey)
        return { request, body in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "t", "refresh_token": "r",
                          "user": { "id": "00000000-0000-0000-0000-000000000000" },
                          "expires_at": 9999999999 }
                        """.utf8))
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "\(jwt)", "refresh_token": "r2",
                          "user": { "id": "00000000-0000-0000-0000-000000000000" },
                          "expires_at": 9999999999 }
                        """.utf8))
            default:
                return try dm(request, body)
            }
        }
    }

    private func makePlaintext(messageID: String, body: String, kind: DirectMessageKind = .ping) -> DirectMessagePlaintext {
        DirectMessagePlaintext(
            messageID: messageID,
            workspaceID: workspaceID,
            senderMemberID: "sender-mid",
            senderPubkeyHex: senderPubkey,
            senderDisplayName: "Sender",
            recipientMemberID: nil,
            recipientPubkeyHex: selfPubkey,
            kind: kind,
            body: body,
            attachment: nil,
            replyTo: nil,
            sentAtMs: 1_700_000_000_000
        )
    }

    // MARK: - Tests

    func testFirstTick_NoCursor_FetchesAndUpsertsAll() async throws {
        let plaintext = makePlaintext(messageID: "00000000-0000-0000-0000-000000000aaa", body: "first message")
        let envelope = try makeEnvelope(plaintext: plaintext)
        let envelopeHex = "\\\\x" + envelope.map { String(format: "%02x", $0) }.joined()
        let wsID = workspaceID
        let sndKey = senderPubkey
        let slfKey = selfPubkey
        let mid = plaintext.messageID

        MockURLProtocol.handler = wrapWithBootstrap(pubkey: selfPubkey) { request, _ in
            guard request.url?.path == "/rest/v1/direct_messages" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            let q = request.url?.query ?? ""
            XCTAssertFalse(q.contains("created_at=gt."), "first tick must not include cursor; got: \(q)")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("""
                    [{
                      "message_id": "\(mid)",
                      "workspace_id": "\(wsID)",
                      "sender_pubkey": "\(sndKey)",
                      "recipient_pubkey": "\(slfKey)",
                      "kind": "ping",
                      "encrypted_payload": "\(envelopeHex)",
                      "cross_post": null,
                      "created_at": "2026-05-14T10:00:00.000Z",
                      "read_at": null, "done_at": null, "done_by_pubkey": null, "reply_to": null
                    }]
                    """.utf8))
        }

        let svc = makeInboxService(supabase: makeSession())
        let count = try await svc.tick(workspaceID: workspaceID)
        XCTAssertEqual(count, 1)

        let row = try db.readSQL { try MessagesMirrorStore.read(messageID: plaintext.messageID, in: $0) }
        XCTAssertEqual(row?.direction, .inbound)
        XCTAssertEqual(row?.body, "first message")
        XCTAssertEqual(row?.kind, .ping)
    }

    func testSecondTick_UsesMaxCursorFromMirror() async throws {
        // Pre-seed mirror with a row at server_created_at_ms = 5000.
        let seeded = DirectMessageMirrorRow(
            messageID: "seeded-1", workspaceID: workspaceID,
            senderPubkeyHex: senderPubkey, senderMemberID: "smid",
            senderDisplayName: "Sender", recipientPubkeyHex: selfPubkey,
            kind: .ping, body: "old", attachment: nil, replyTo: nil,
            sentAtMs: 4000, serverCreatedAtMs: 5000,
            readAtMs: nil, doneAtMs: nil, doneByPubkeyHex: nil,
            direction: .inbound, lastSyncedAtMs: 5000
        )
        try db.writeSQL { try MessagesMirrorStore.upsert(seeded, in: $0) }

        MockURLProtocol.handler = wrapWithBootstrap(pubkey: selfPubkey) { request, _ in
            let q = request.url?.query ?? ""
            XCTAssertTrue(q.contains("created_at=gt."), "second tick must include cursor; got: \(q)")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("[]".utf8))
        }
        let svc = makeInboxService(supabase: makeSession())
        let count = try await svc.tick(workspaceID: workspaceID)
        XCTAssertEqual(count, 0)
    }

    func testTickIdempotent_SecondTickSameRowReturnsZero() async throws {
        let plaintext = makePlaintext(messageID: "idemp-1", body: "x")
        let envelope = try makeEnvelope(plaintext: plaintext)
        let envelopeHex = "\\\\x" + envelope.map { String(format: "%02x", $0) }.joined()
        let wsID = workspaceID
        let sndKey = senderPubkey
        let slfKey = selfPubkey
        let mid = plaintext.messageID

        MockURLProtocol.handler = wrapWithBootstrap(pubkey: selfPubkey) { request, _ in
            guard request.url?.path == "/rest/v1/direct_messages" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("""
                    [{
                      "message_id": "\(mid)",
                      "workspace_id": "\(wsID)",
                      "sender_pubkey": "\(sndKey)",
                      "recipient_pubkey": "\(slfKey)",
                      "kind": "ping",
                      "encrypted_payload": "\(envelopeHex)",
                      "cross_post": null,
                      "created_at": "2026-05-14T10:00:00.000Z",
                      "read_at": null, "done_at": null, "done_by_pubkey": null, "reply_to": null
                    }]
                    """.utf8))
        }

        let svc = makeInboxService(supabase: makeSession())
        _ = try await svc.tick(workspaceID: workspaceID)
        _ = try await svc.tick(workspaceID: workspaceID)

        // Only one mirror row exists despite two ticks.
        let count = try db.readSQL { rawDB in
            try Int.fetchOne(rawDB, sql: "SELECT count(*) FROM \(Schema.MessagesMirror.tableName)")
        }
        XCTAssertEqual(count, 1)
    }

    func testDecryptFailure_SkippedNotThrown() async throws {
        let plaintextValid = makePlaintext(messageID: "valid-1", body: "ok")
        let envelopeValid = try makeEnvelope(plaintext: plaintextValid)
        let envelopeValidHex = "\\\\x" + envelopeValid.map { String(format: "%02x", $0) }.joined()
        var tamperedEnvelope = envelopeValid
        tamperedEnvelope[tamperedEnvelope.startIndex] = 0x99
        let tamperedHex = "\\\\x" + tamperedEnvelope.map { String(format: "%02x", $0) }.joined()
        let wsID = workspaceID
        let sndKey = senderPubkey
        let slfKey = selfPubkey
        let validID = plaintextValid.messageID

        MockURLProtocol.handler = wrapWithBootstrap(pubkey: selfPubkey) { request, _ in
            guard request.url?.path == "/rest/v1/direct_messages" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("""
                    [
                      {
                        "message_id": "tampered-1",
                        "workspace_id": "\(wsID)",
                        "sender_pubkey": "\(sndKey)",
                        "recipient_pubkey": "\(slfKey)",
                        "kind": "ping",
                        "encrypted_payload": "\(tamperedHex)",
                        "cross_post": null,
                        "created_at": "2026-05-14T10:00:00.000Z",
                        "read_at": null, "done_at": null, "done_by_pubkey": null, "reply_to": null
                      },
                      {
                        "message_id": "\(validID)",
                        "workspace_id": "\(wsID)",
                        "sender_pubkey": "\(sndKey)",
                        "recipient_pubkey": "\(slfKey)",
                        "kind": "ping",
                        "encrypted_payload": "\(envelopeValidHex)",
                        "cross_post": null,
                        "created_at": "2026-05-14T10:01:00.000Z",
                        "read_at": null, "done_at": null, "done_by_pubkey": null, "reply_to": null
                      }
                    ]
                    """.utf8))
        }

        let svc = makeInboxService(supabase: makeSession())
        let count = try await svc.tick(workspaceID: workspaceID)
        XCTAssertEqual(count, 1, "tampered row skipped; valid row processed")

        let tampered = try db.readSQL { try MessagesMirrorStore.read(messageID: "tampered-1", in: $0) }
        XCTAssertNil(tampered, "tampered row must not be persisted")
        let valid = try db.readSQL { try MessagesMirrorStore.read(messageID: plaintextValid.messageID, in: $0) }
        XCTAssertNotNil(valid)
    }

    func testC4_PlaintextKindWinsOverServerKind() async throws {
        // Server tries to change task → ping while ciphertext claims task.
        let plaintext = makePlaintext(messageID: "tamper-kind-1", body: "is a task", kind: .task)
        let envelope = try makeEnvelope(plaintext: plaintext)
        let envelopeHex = "\\\\x" + envelope.map { String(format: "%02x", $0) }.joined()
        let wsID = workspaceID
        let sndKey = senderPubkey
        let slfKey = selfPubkey
        let mid = plaintext.messageID

        MockURLProtocol.handler = wrapWithBootstrap(pubkey: selfPubkey) { request, _ in
            guard request.url?.path == "/rest/v1/direct_messages" else {
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("""
                    [{
                      "message_id": "\(mid)",
                      "workspace_id": "\(wsID)",
                      "sender_pubkey": "\(sndKey)",
                      "recipient_pubkey": "\(slfKey)",
                      "kind": "ping",
                      "encrypted_payload": "\(envelopeHex)",
                      "cross_post": null,
                      "created_at": "2026-05-14T10:00:00.000Z",
                      "read_at": null, "done_at": null, "done_by_pubkey": null, "reply_to": null
                    }]
                    """.utf8))
        }

        let svc = makeInboxService(supabase: makeSession())
        _ = try await svc.tick(workspaceID: workspaceID)

        let row = try db.readSQL { try MessagesMirrorStore.read(messageID: plaintext.messageID, in: $0) }
        XCTAssertEqual(row?.kind, .task, "C4 fix: authenticated plaintext kind must win over server-controlled row.kind")
    }
}

// MARK: - Inline test codec — mirrors DirectMessageServiceTests pattern.

private struct InboxTestCodec: DirectMessageBlobCodec {
    func encode(_ plaintext: DirectMessagePlaintext, keyID: Data, teamKey: Data) throws -> Data {
        var bytes = Data()
        bytes.append(0x03)
        bytes.append(keyID)
        bytes.append(Data(repeating: 0, count: 12))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(plaintext)
        bytes.append(json)
        bytes.append(Data(repeating: 0, count: 16))
        return bytes
    }

    func decode(_ bytes: Data, teamKey: Data) throws -> DirectMessagePlaintext {
        guard bytes.count > 29 + 16 else { throw LeafError.directMessageBlobMalformed }
        guard bytes[bytes.startIndex] == 0x03 else { throw LeafError.directMessageBlobMalformed }
        let start = bytes.index(bytes.startIndex, offsetBy: 29)
        let end = bytes.index(bytes.endIndex, offsetBy: -16)
        let jsonSlice = bytes[start..<end]
        return try JSONDecoder().decode(DirectMessagePlaintext.self, from: Data(jsonSlice))
    }
}
