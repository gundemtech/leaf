// Phase 5.2.D — InviteService admin-orchestrator tests.
// "MockRelayClient" = real RelayClient + URLProtocol stub (per spec §4.5
// signature locks `RelayClient` as concrete actor, not protocol).
// Recording doubles for InviteKDF / InviteBlobCodec capture chain args.

import XCTest
import CryptoKit
import Foundation
@testable import LeafCore

private final class InviteServiceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Self.drainBody(from: request)
        Self.lastBody = body
        Self.lastRequest = request
        do {
            let (resp, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drainBody(from req: URLRequest) -> Data {
        if let body = req.httpBody { return body }
        guard let stream = req.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

private final class RecordingInviteKDF: InviteKDF, @unchecked Sendable {
    var stubKey = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
    var error: Error?
    var calls: [(SharedSecret, String)] = []

    func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
        calls.append((sharedSecret, otp))
        if let e = error { throw e }
        return stubKey
    }
}

private final class RecordingInviteBlobCodec: InviteBlobCodec, @unchecked Sendable {
    var stubBlob = InviteBlob(bytes: Data([0x02] + (0..<60).map { _ in UInt8(0xCD) }))
    var encodeError: Error?
    var encodeCalls: [(InvitePlaintext, Data, SymmetricKey)] = []

    func encode(_ plaintext: InvitePlaintext, adminPubkey: Data, wrapKey: SymmetricKey) throws -> InviteBlob {
        encodeCalls.append((plaintext, adminPubkey, wrapKey))
        if let e = encodeError { throw e }
        return stubBlob
    }

    func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
        fatalError("InviteService 5.2.D doesn't decode")
    }
}

final class InviteServiceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!
    private var db: Database!
    private var fixedNow: Date!
    private var orgID: String!
    private var memberID: String!
    private var teamKeyID: String!
    private var teamKeyBytes: Data!
    private var adminPriv: Curve25519.KeyAgreement.PrivateKey!

    override func setUp() async throws {
        // Track 5 / S3 — Phase 5.5 RelayClient-shape tests retired. SupabaseClient + Track 5 §12 URL coverage
        // lives in InviteServiceTrackFiveTests (Task 7 of Track 5 / S3 plan). Retain skeleton + setUp for
        // future re-anchoring of crypto-round-trip coverage via SupabaseClient mock if needed.
        try XCTSkipIf(true, "Track 5 / S3 — Phase 5.5 RelayClient path retired; coverage in SupabaseClientPostInviteTests + (future) InviteServiceTrackFiveTests")

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("invite-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        fixedNow = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC

        // seed minimal org/member/team_key + keystore.
        orgID = UUID().uuidString.lowercased()
        memberID = UUID().uuidString.lowercased()
        teamKeyID = UUID().uuidString.lowercased()
        teamKeyBytes = Data(repeating: 0x42, count: 32)
        adminPriv = Curve25519.KeyAgreement.PrivateKey()

        let pubkeyHex = adminPriv.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let member = TeamMember(id: memberID, workspaceID: orgID, role: .admin,
                                pubkeyHex: pubkeyHex, displayName: "Admin User",
                                addedAt: fixedNow, removedAt: nil)
        let org = Workspace(id: orgID, name: "Test Org", createdAt: fixedNow, createdByMemberID: memberID)
        let teamKey = TeamKey(id: teamKeyID, workspaceID: orgID, generatedAt: fixedNow, deprecatedAt: nil,
                              generatedByMemberID: memberID)
        try db.upsertWorkspace(org)
        try db.insertTeamMember(member)
        try db.insertTeamKey(teamKey)
        try TeamKeystore.writeTeamKey(teamKeyBytes, workspaceID: orgID, keyID: teamKeyID, at: keystoreRoot)
        try TeamKeystore.writeX25519Private(adminPriv.rawRepresentation, at: keystoreRoot)

        InviteServiceMockURLProtocol.handler = nil
        InviteServiceMockURLProtocol.lastBody = nil
        InviteServiceMockURLProtocol.lastRequest = nil
    }

    override func tearDown() async throws {
        InviteServiceMockURLProtocol.handler = nil
        InviteServiceMockURLProtocol.lastBody = nil
        InviteServiceMockURLProtocol.lastRequest = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeRelayClient() -> RelayClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InviteServiceMockURLProtocol.self]
        return RelayClient(baseURL: URL(string: "https://stub.example")!,
                           urlSession: URLSession(configuration: config))
    }

    /// Track 5 / S3 — stub SupabaseClient (never actually invoked; setUp skips all tests).
    private func makeStubSupabase() -> SupabaseClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InviteServiceMockURLProtocol.self]
        return SupabaseClient(
            baseURL: URL(string: "https://stub.supabase")!,
            anonKey: "stub",
            urlSession: URLSession(configuration: config),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0, count: 32)) }
        )
    }

    private func stub201(token: String, expiresAtMs: Int64) {
        InviteServiceMockURLProtocol.handler = { req, _ in
            let body = """
            {"token":"\(token)","expires_at_ms":\(expiresAtMs)}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        }
    }

    private func makeService(
        kdf: InviteKDF = RecordingInviteKDF(),
        codec: InviteBlobCodec = RecordingInviteBlobCodec(),
        otp: String = "654321",
        identity: Curve25519.KeyAgreement.PrivateKey? = nil
    ) -> InviteService {
        let now = self.fixedNow!
        let priv = identity ?? adminPriv
        return InviteService(
            database: db,
            supabase: makeStubSupabase(),
            inviteKDF: kdf,
            inviteBlobCodec: codec,
            keystoreRoot: keystoreRoot,
            now: { now },
            randomOTP: { otp },
            identity: { priv! }
        )
    }

    // MARK: - 1

    func testGenerateInvite_HappyPath_ReturnsExpectedOutbound() async throws {
        stub201(token: "tok_happy", expiresAtMs: 1_700_086_400_000)
        let svc = makeService()
        let invitee = String(repeating: "a", count: 64)

        let outbound = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: invitee)

        XCTAssertEqual(outbound.token, "tok_happy")
        XCTAssertEqual(outbound.otp, "654321")
        XCTAssertEqual(outbound.expiresAtMs, 1_700_086_400_000)
        XCTAssertEqual(outbound.inviteePubkeyHex, invitee)
    }

    // MARK: - 2

    func testGenerateInvite_ReadsActiveTeamKeyBytes() async throws {
        stub201(token: "t", expiresAtMs: 1)
        let codec = RecordingInviteBlobCodec()
        let svc = makeService(codec: codec)
        _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: String(repeating: "b", count: 64))

        XCTAssertEqual(codec.encodeCalls.count, 1)
        let plaintext = codec.encodeCalls[0].0
        let decoded = try XCTUnwrap(Data(base64Encoded: plaintext.teamKeyBase64))
        XCTAssertEqual(decoded, teamKeyBytes)
        XCTAssertEqual(plaintext.teamKeyID, teamKeyID)
    }

    // MARK: - 3

    func testGenerateInvite_PassesAdminPubkeyToCodec() async throws {
        stub201(token: "t", expiresAtMs: 1)
        let codec = RecordingInviteBlobCodec()
        let svc = makeService(codec: codec)
        _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: String(repeating: "c", count: 64))

        XCTAssertEqual(codec.encodeCalls.count, 1)
        XCTAssertEqual(codec.encodeCalls[0].1, adminPriv.publicKey.rawRepresentation)
    }

    // MARK: - 4

    func testGenerateInvite_PassesLowercaseHexToRelay() async throws {
        stub201(token: "t", expiresAtMs: 1)
        let svc = makeService()
        let uppercased = "AABBCCDD" + String(repeating: "E", count: 56)
        _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: uppercased)

        let body = try XCTUnwrap(InviteServiceMockURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["member_pubkey_hex"] as? String,
                       "aabbccdd" + String(repeating: "e", count: 56))
    }

    // MARK: - 5

    func testGenerateInvite_ExpiresAt24Hours() async throws {
        // stub returns `expires_at_ms` matching what InviteService computed (relay echoes
        // request value — verified at body-shape level).
        stub201(token: "t", expiresAtMs: 1_700_086_400_000)
        let svc = makeService()
        _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: String(repeating: "d", count: 64))

        let body = try XCTUnwrap(InviteServiceMockURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let expires = (json["expires_at_ms"] as? NSNumber)?.int64Value
        let nowMs = Int64(fixedNow.timeIntervalSince1970 * 1000)
        XCTAssertEqual(expires, nowMs + 24 * 60 * 60 * 1000)
    }

    // MARK: - 6

    func testGenerateInvite_BadHex_ThrowsInvalidPayload() async {
        let svc = makeService()
        do {
            _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: "not-hex")
            XCTFail("expected throw")
        } catch LeafError.invalidPayload {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }

        do {
            _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: String(repeating: "z", count: 64))
            XCTFail("expected throw")
        } catch LeafError.invalidPayload {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - 7

    func testGenerateInvite_NoOrg_ThrowsDatabaseUnavailable() async throws {
        // wipe DB.
        let emptyDir = tempDir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let emptyDB = try Database.openForWrite(at: emptyDir.appendingPathComponent("events.sqlite"),
                                                config: .weakDefaults, encryption: .deterministicTest)
        let nowLocal = fixedNow!
        let privLocal = adminPriv!
        let svc = InviteService(
            database: emptyDB,
            supabase: makeStubSupabase(),
            inviteKDF: RecordingInviteKDF(),
            inviteBlobCodec: RecordingInviteBlobCodec(),
            keystoreRoot: keystoreRoot,
            now: { nowLocal },
            randomOTP: { "654321" },
            identity: { privLocal }
        )

        do {
            _ = try await svc.generateInvite(workspaceID: "missing-ws", inviteePubkeyHex: String(repeating: "a", count: 64))
            XCTFail("expected throw")
        } catch LeafError.databaseUnavailable {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - 8

    func testGenerateInvite_NoActiveTeamKey_ThrowsDatabaseUnavailable() async throws {
        // create new DB with org+member but no team_keys row.
        let dir = tempDir.appendingPathComponent("noteamkey", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db2 = try Database.openForWrite(at: dir.appendingPathComponent("events.sqlite"),
                                            config: .weakDefaults, encryption: .deterministicTest)
        let pub = adminPriv.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        try db2.upsertWorkspace(Workspace(id: orgID, name: "X", createdAt: fixedNow, createdByMemberID: memberID))
        try db2.insertTeamMember(TeamMember(id: memberID, workspaceID: orgID, role: .admin,
                                            pubkeyHex: pub, displayName: "U",
                                            addedAt: fixedNow, removedAt: nil))
        let nowLocal = fixedNow!
        let privLocal = adminPriv!
        let svc = InviteService(
            database: db2,
            supabase: makeStubSupabase(),
            inviteKDF: RecordingInviteKDF(),
            inviteBlobCodec: RecordingInviteBlobCodec(),
            keystoreRoot: keystoreRoot,
            now: { nowLocal },
            randomOTP: { "654321" },
            identity: { privLocal }
        )

        do {
            _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: String(repeating: "a", count: 64))
            XCTFail("expected throw")
        } catch LeafError.databaseUnavailable {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - 9

    func testGenerateInvite_KDFFails_PropagatesInvalidPayload() async {
        let kdf = RecordingInviteKDF()
        kdf.error = LeafError.invalidPayload
        let svc = makeService(kdf: kdf)
        do {
            _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: String(repeating: "a", count: 64))
            XCTFail("expected throw")
        } catch LeafError.invalidPayload {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - 10

    func testGenerateInvite_RelayFails_PropagatesRelayUnreachable() async {
        InviteServiceMockURLProtocol.handler = { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, nil)
        }
        let svc = makeService()
        do {
            _ = try await svc.generateInvite(workspaceID: orgID, inviteePubkeyHex: String(repeating: "a", count: 64))
            XCTFail("expected throw")
        } catch let LeafError.relayUnreachable(reason) {
            XCTAssertEqual(reason, "server-error")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - 11

    func testRevokeInvite_CallsRelayDelete() async throws {
        InviteServiceMockURLProtocol.handler = { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil,
                                       headerFields: nil)!
            return (resp, nil)
        }
        let svc = makeService()
        try await svc.revokeInvite(token: "tok_to_revoke")

        let req = try XCTUnwrap(InviteServiceMockURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.path, "/v1/invite/tok_to_revoke")
        XCTAssertEqual(req.httpMethod, "DELETE")
    }

    // MARK: - Phase 5.5.B JoinCode overload

    func testGenerateInvite_JoinCode_FormattedDelegatesToHex() async throws {
        stub201(token: "tok_jc1", expiresAtMs: 1_700_086_400_000)
        let svc = makeService()
        let pubkey = Data(repeating: 0x42, count: 32)
        let joinCode = try JoinCode.encode(pubkey: pubkey)

        let outbound = try await svc.generateInvite(workspaceID: orgID, inviteeJoinCode: joinCode)

        let expectedHex = pubkey.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(outbound.inviteePubkeyHex, expectedHex)
        XCTAssertEqual(outbound.token, "tok_jc1")
    }

    func testGenerateInvite_JoinCode_LegacyHexAccepted() async throws {
        stub201(token: "tok_jc2", expiresAtMs: 1_700_086_400_000)
        let svc = makeService()
        let pubkey = Data(repeating: 0x99, count: 32)
        let hex = pubkey.map { String(format: "%02x", $0) }.joined()

        let outbound = try await svc.generateInvite(workspaceID: orgID, inviteeJoinCode: hex)

        XCTAssertEqual(outbound.inviteePubkeyHex, hex)
    }

    func testGenerateInvite_JoinCode_MalformedThrowsLeafError() async throws {
        stub201(token: "irrelevant", expiresAtMs: 1)
        let svc = makeService()
        do {
            _ = try await svc.generateInvite(workspaceID: orgID, inviteeJoinCode: "garbage-input-not-a-code")
            XCTFail("expected throw")
        } catch LeafError.joinCodeMalformed {
            // expected
        }
    }
}
