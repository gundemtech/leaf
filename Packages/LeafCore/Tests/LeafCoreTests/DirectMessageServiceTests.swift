// Phase Track-5 S4 — DirectMessageService sender orchestrator coverage.

import XCTest
import CryptoKit
@testable import LeafCore

final class DirectMessageServiceTests: XCTestCase {
    private var tempDir: URL!
    private var db: LeafCore.Database!
    private let workspaceID = "11111111-1111-1111-1111-111111111111"
    private let teamKeyID = "22222222-2222-2222-2222-222222222222"
    private let selfMemberID = "33333333-3333-3333-3333-333333333333"
    private let selfPubkey = String(repeating: "a", count: 64)
    private let recipientPubkey = String(repeating: "b", count: 64)

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-dm-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try LeafCore.Database.openForWrite(
            at: tempDir.appendingPathComponent("events.sqlite"),
            config: .weakDefaults,
            encryption: .deterministicTest
        )
        // Seed workspace + self team member + active team key + keystore.
        try db.upsertWorkspace(Workspace(
            id: workspaceID, name: "Acme",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: selfMemberID
        ))
        try db.insertTeamMember(TeamMember(
            id: selfMemberID, workspaceID: workspaceID, role: .admin,
            pubkeyHex: selfPubkey, displayName: "Sasha",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), removedAt: nil
        ))
        try db.insertTeamKey(TeamKey(
            id: teamKeyID, workspaceID: workspaceID,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deprecatedAt: nil, generatedByMemberID: selfMemberID
        ))
        let teamKeyBytes = Data(repeating: 0xCC, count: 32)
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

    /// Bootstrap handler — covers signup/register/refresh sequence.
    private func bootstrapHandler() -> @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data) {
        let jwt = makeJWT(pubkey: selfPubkey)
        return { request, _ in
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
                throw URLError(.badServerResponse)
            }
        }
    }

    func testSend_EmptyBody_ThrowsInvalidPayload() async throws {
        MockURLProtocol.handler = bootstrapHandler()
        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
        let svc = DirectMessageService(
            database: db,
            supabase: supabase,
            codec: UnimplementedDirectMessageBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore")
        )
        do {
            _ = try await svc.send(
                workspaceID: workspaceID,
                recipientPubkeyHex: recipientPubkey,
                recipientMemberID: nil,
                kind: .handoff,
                body: "   "
            )
            XCTFail("expected throw")
        } catch LeafError.invalidPayload {
            // pass
        }
    }

    func testSend_BodyTooLarge_ThrowsBodyTooLarge() async throws {
        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
        let svc = DirectMessageService(
            database: db,
            supabase: supabase,
            codec: UnimplementedDirectMessageBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore")
        )
        let huge = String(repeating: "x", count: DirectMessageService.bodyMaxBytes + 1)
        do {
            _ = try await svc.send(
                workspaceID: workspaceID,
                recipientPubkeyHex: recipientPubkey,
                recipientMemberID: nil,
                kind: .handoff,
                body: huge
            )
            XCTFail("expected throw")
        } catch LeafError.directMessageBodyTooLarge {
            // pass
        }
    }

    func testSend_BadRecipientHex_ThrowsInvalidPayload() async throws {
        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
        let svc = DirectMessageService(
            database: db, supabase: supabase,
            codec: UnimplementedDirectMessageBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore")
        )
        do {
            _ = try await svc.send(
                workspaceID: workspaceID,
                recipientPubkeyHex: "xyz",  // too short, non-hex
                recipientMemberID: nil,
                kind: .handoff,
                body: "ok"
            )
            XCTFail("expected throw")
        } catch LeafError.invalidPayload {
            // pass
        }
    }

    func testSend_FullPipeline_InsertsMirrorOutbound() async throws {
        let messageID = "00000000-0000-0000-0000-000000000aaa"
        let createdAtISO = "2026-05-14T10:00:00.000Z"

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            // Bootstrap arms.
            if path == "/auth/v1/signup" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "t", "refresh_token": "r",
                          "user": { "id": "00000000-0000-0000-0000-000000000000" },
                          "expires_at": 9999999999 }
                        """.utf8))
            }
            if path == "/functions/v1/register_pubkey" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            }
            if path == "/auth/v1/token" {
                let header = #"{"alg":"HS256","typ":"JWT"}"#
                let pubkey = String(repeating: "a", count: 64)
                let payload = #"{"pubkey":"\#(pubkey)"}"#
                func b64url(_ s: String) -> String {
                    Data(s.utf8).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                }
                let jwt = "\(b64url(header)).\(b64url(payload)).sig"
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "\(jwt)", "refresh_token": "r2",
                          "user": { "id": "00000000-0000-0000-0000-000000000000" },
                          "expires_at": 9999999999 }
                        """.utf8))
            }
            // DM POST.
            if path == "/rest/v1/direct_messages" && request.httpMethod == "POST" {
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        [{ "message_id": "\(messageID)", "created_at": "\(createdAtISO)" }]
                        """.utf8))
            }
            // APNs push.
            if path == "/functions/v1/apns_push" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true,"devices_pushed":1,"errors":[]}"#.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        // Custom test codec that returns predictable envelope bytes.
        let testCodec = TestDirectMessageBlobCodec()

        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
        let selfPub = selfPubkey
        let svc = DirectMessageService(
            database: db,
            supabase: supabase,
            codec: testCodec,
            keystoreRoot: tempDir.appendingPathComponent("keystore"),
            generateMessageID: { messageID },
            selfPubkeyHex: { selfPub }
        )

        let result = try await svc.send(
            workspaceID: workspaceID,
            recipientPubkeyHex: recipientPubkey,
            recipientMemberID: nil,
            kind: .ping,
            body: "hi from S4 smoke test",
            notify: true
        )

        XCTAssertEqual(result.messageID, messageID)
        XCTAssertEqual(result.pushDispatchStatus, .sent)

        // Mirror row written.
        let row = try db.readSQL { try MessagesMirrorStore.read(messageID: messageID, in: $0) }
        XCTAssertEqual(row?.direction, .outbound)
        XCTAssertEqual(row?.body, "hi from S4 smoke test")
        XCTAssertEqual(row?.kind, .ping)
        XCTAssertEqual(row?.senderPubkeyHex, selfPubkey)
        XCTAssertEqual(row?.recipientPubkeyHex, recipientPubkey)
    }

    func testSend_NotifyOff_SkipsAPNs() async throws {
        let messageID = "00000000-0000-0000-0000-000000000bbb"
        let apnsCalledBox = APNsCalledBox()

        MockURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            if path == "/auth/v1/signup" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "t", "refresh_token": "r",
                          "user": { "id": "00000000-0000-0000-0000-000000000000" },
                          "expires_at": 9999999999 }
                        """.utf8))
            }
            if path == "/functions/v1/register_pubkey" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            }
            if path == "/auth/v1/token" {
                let pubkey = String(repeating: "a", count: 64)
                let payload = #"{"pubkey":"\#(pubkey)"}"#
                func b64url(_ s: String) -> String {
                    Data(s.utf8).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                }
                let jwt = "\(b64url(#"{"alg":"HS256","typ":"JWT"}"#)).\(b64url(payload)).sig"
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "\(jwt)", "refresh_token": "r2",
                          "user": { "id": "00000000-0000-0000-0000-000000000000" },
                          "expires_at": 9999999999 }
                        """.utf8))
            }
            if path == "/rest/v1/direct_messages" && request.httpMethod == "POST" {
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        [{ "message_id": "\(messageID)", "created_at": "2026-05-14T10:00:00Z" }]
                        """.utf8))
            }
            if path == "/functions/v1/apns_push" {
                apnsCalledBox.markCalled()
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true,"devices_pushed":1,"errors":[]}"#.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
        let selfPub = selfPubkey
        let svc = DirectMessageService(
            database: db, supabase: supabase,
            codec: TestDirectMessageBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore"),
            generateMessageID: { messageID },
            selfPubkeyHex: { selfPub }
        )

        let result = try await svc.send(
            workspaceID: workspaceID,
            recipientPubkeyHex: recipientPubkey,
            recipientMemberID: nil,
            kind: .ping,
            body: "x",
            notify: false
        )
        XCTAssertEqual(result.pushDispatchStatus, .skipped)
        XCTAssertFalse(apnsCalledBox.wasCalled, "apns_push should NOT have been called when notify=false")
    }

    /// Regression — joiner-device sender resolution. On an invitee's device the
    /// roster is `ORDER BY added_at_ms ASC` = [admin(earlier), self(later)], so
    /// `members.first` is the ADMIN, not self. The sender baked into the
    /// encrypted plaintext / outbound mirror MUST be self (identity pubkey) —
    /// otherwise the recipient's C2 trust-gate (`plaintext.sender == row.sender`)
    /// silently drops every DM the joiner sends.
    func testSend_JoinerDevice_UsesSelfNotFirstRosterMember() async throws {
        let messageID = "00000000-0000-0000-0000-000000000ccc"
        let adminMemberID = "44444444-4444-4444-4444-444444444444"
        let adminPubkey = String(repeating: "c", count: 64)
        // Admin row added BEFORE self → first in `added_at_ms ASC` order.
        try db.insertTeamMember(TeamMember(
            id: adminMemberID, workspaceID: workspaceID, role: .admin,
            pubkeyHex: adminPubkey, displayName: "Acme",
            addedAt: Date(timeIntervalSince1970: 1_600_000_000), removedAt: nil
        ))

        MockURLProtocol.handler = { request, _ in
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
                let payload = #"{"pubkey":"\#(String(repeating: "a", count: 64))"}"#
                func b64url(_ s: String) -> String {
                    Data(s.utf8).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                }
                let jwt = "\(b64url(#"{"alg":"HS256","typ":"JWT"}"#)).\(b64url(payload)).sig"
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        { "access_token": "\(jwt)", "refresh_token": "r2",
                          "user": { "id": "00000000-0000-0000-0000-000000000000" },
                          "expires_at": 9999999999 }
                        """.utf8))
            case "/rest/v1/direct_messages" where request.httpMethod == "POST":
                return (HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                        Data("""
                        [{ "message_id": "\(messageID)", "created_at": "2026-05-14T10:00:00Z" }]
                        """.utf8))
            default:
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
        let selfPub = selfPubkey
        let svc = DirectMessageService(
            database: db, supabase: supabase,
            codec: TestDirectMessageBlobCodec(),
            keystoreRoot: tempDir.appendingPathComponent("keystore"),
            generateMessageID: { messageID },
            selfPubkeyHex: { selfPub }
        )

        _ = try await svc.send(
            workspaceID: workspaceID,
            recipientPubkeyHex: recipientPubkey,
            recipientMemberID: nil,
            kind: .ping,
            body: "reply from the joiner",
            notify: false
        )

        let row = try db.readSQL { try MessagesMirrorStore.read(messageID: messageID, in: $0) }
        XCTAssertEqual(
            row?.senderPubkeyHex, selfPubkey,
            "outbound DM must be authored by self (identity pubkey), not the first roster member (admin)"
        )
        XCTAssertEqual(row?.senderMemberID, selfMemberID)
    }

    func testSend_MalformedActiveTeamKeyUUID_ThrowsInvalidPayload() async throws {
        // H1 (security audit): a malformed active team-key UUID must hard-fail, not
        // silently degrade to 16 zero bytes used as the crypto keyID.
        let wsBad = "44444444-4444-4444-4444-444444444444"
        let badKeyID = "not-a-valid-uuid"
        let badMemberID = "55555555-5555-5555-5555-555555555555"
        let badSelfPubkey = String(repeating: "c", count: 64)
        let keystoreRoot = tempDir.appendingPathComponent("keystore")
        try db.upsertWorkspace(Workspace(
            id: wsBad, name: "BadKey",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: badMemberID
        ))
        try db.insertTeamMember(TeamMember(
            id: badMemberID, workspaceID: wsBad, role: .admin,
            pubkeyHex: badSelfPubkey, displayName: "Sasha",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000), removedAt: nil
        ))
        try db.insertTeamKey(TeamKey(
            id: badKeyID, workspaceID: wsBad,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deprecatedAt: nil, generatedByMemberID: badMemberID
        ))
        try TeamKeystore.writeTeamKey(Data(repeating: 0xCC, count: 32),
                                      workspaceID: wsBad,
                                      keyID: badKeyID,
                                      at: keystoreRoot)

        let supabase = SupabaseClient(
            baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
            urlSession: makeURLSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32)) }
        )
        let svc = DirectMessageService(
            database: db, supabase: supabase,
            codec: UnimplementedDirectMessageBlobCodec(),
            keystoreRoot: keystoreRoot,
            selfPubkeyHex: { badSelfPubkey }
        )
        do {
            _ = try await svc.send(
                workspaceID: wsBad,
                recipientPubkeyHex: recipientPubkey,
                recipientMemberID: nil,
                kind: .handoff,
                body: "ok"
            )
            XCTFail("expected throw on malformed active team key UUID")
        } catch LeafError.invalidPayload {
            // pass — keyID derivation rejected the malformed UUID before encrypt
        }
    }
}

// MARK: - Test helper — thread-safe boolean box.

private final class APNsCalledBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _called = false

    func markCalled() {
        lock.lock(); defer { lock.unlock() }
        _called = true
    }

    var wasCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _called
    }
}

// MARK: - Test fixture codec — minimal encode/decode passthrough with valid envelope shape.

private struct TestDirectMessageBlobCodec: DirectMessageBlobCodec {
    func encode(_ plaintext: DirectMessagePlaintext, keyID: Data, teamKey: Data) throws -> Data {
        // Produce a deterministic envelope: version + keyID + nonce(zeros) + body(json) + tag(zeros)
        var bytes = Data()
        bytes.append(0x03)  // version
        bytes.append(keyID)
        bytes.append(Data(repeating: 0, count: 12))  // nonce
        let json = try JSONEncoder().encode(plaintext)
        bytes.append(json)
        bytes.append(Data(repeating: 0, count: 16))  // tag
        return bytes
    }

    func decode(_ bytes: Data, teamKey: Data) throws -> DirectMessagePlaintext {
        // Skip 1 + 16 + 12 = 29 bytes; tail 16 bytes is tag.
        guard bytes.count > 29 + 16 else { throw LeafError.directMessageBlobMalformed }
        let start = bytes.index(bytes.startIndex, offsetBy: 29)
        let end = bytes.index(bytes.endIndex, offsetBy: -16)
        let jsonSlice = bytes[start..<end]
        return try JSONDecoder().decode(DirectMessagePlaintext.self, from: Data(jsonSlice))
    }
}
