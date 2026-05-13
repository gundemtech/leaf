// Phase 5.2.E — InviteAcceptService invitee-orchestrator tests.
// fetchInvite: 3 cases via real RelayClient + URLProtocol stub (mirror
// InviteServiceTests harness). acceptInvite: full crypto chain in C3.

import XCTest
import CryptoKit
import Foundation
@testable import LeafCore

private final class AcceptServiceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lastRequest = request
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class StubInviteKDF: InviteKDF, @unchecked Sendable {
    func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 0xAB, count: 32))
    }
}

private final class StubInviteBlobCodec: InviteBlobCodec, @unchecked Sendable {
    func encode(_ plaintext: InvitePlaintext, adminPubkey: Data, wrapKey: SymmetricKey) throws -> InviteBlob {
        fatalError("unused in accept path")
    }
    func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
        fatalError("acceptInvite tests use RecordingAcceptCodec")
    }
}

/// Programmable codec для acceptInvite tests — capture wrapKey + return stub
/// plaintext (or throw).
private final class RecordingAcceptCodec: InviteBlobCodec, @unchecked Sendable {
    var stubPlaintext: InvitePlaintext?
    var decodeError: Error?
    var capturedWrapKey: SymmetricKey?
    var decodeCalls: Int = 0

    func encode(_ plaintext: InvitePlaintext, adminPubkey: Data, wrapKey: SymmetricKey) throws -> InviteBlob {
        fatalError("encode unused in accept path")
    }

    func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
        decodeCalls += 1
        capturedWrapKey = wrapKey
        if let e = decodeError { throw e }
        guard let pt = stubPlaintext else { throw LeafError.inviteBlobMalformed }
        return pt
    }
}

/// Build a syntactically-valid blob (≥33B, version 0x02) that passes
/// `InviteBlobHeader.peek`. Bytes after the 33-byte prefix are arbitrary —
/// our RecordingAcceptCodec doesn't actually decrypt, just returns stub.
private func makeStubBlob(adminPubkey: Data) -> InviteBlob {
    var bytes = Data()
    bytes.append(0x02)                                  // version
    bytes.append(adminPubkey)                           // 32B
    bytes.append(Data(repeating: 0xCC, count: 12))      // nonce
    bytes.append(Data(repeating: 0xDD, count: 80))      // ciphertext
    bytes.append(Data(repeating: 0xEE, count: 16))      // tag
    return InviteBlob(bytes: bytes)
}

final class InviteAcceptServiceTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!
    private var db: Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("invite-accept-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        AcceptServiceMockURLProtocol.handler = nil
        AcceptServiceMockURLProtocol.lastRequest = nil
    }

    override func tearDown() async throws {
        AcceptServiceMockURLProtocol.handler = nil
        AcceptServiceMockURLProtocol.lastRequest = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRelayClient() -> RelayClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AcceptServiceMockURLProtocol.self]
        return RelayClient(baseURL: URL(string: "https://stub.example")!,
                           urlSession: URLSession(configuration: config))
    }

    private func makeService() -> InviteAcceptService {
        InviteAcceptService(
            database: db,
            relayClient: makeRelayClient(),
            inviteKDF: StubInviteKDF(),
            inviteBlobCodec: StubInviteBlobCodec(),
            keystoreRoot: keystoreRoot,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            identity: { Curve25519.KeyAgreement.PrivateKey() },
            generateMemberID: { "fixed-member-id" }
        )
    }

    private func makeAcceptService(
        codec: any InviteBlobCodec,
        identity: @Sendable @escaping () throws -> Curve25519.KeyAgreement.PrivateKey,
        nowMs: Int64 = 1_700_000_000_000
    ) -> InviteAcceptService {
        InviteAcceptService(
            database: db,
            relayClient: makeRelayClient(),
            inviteKDF: StubInviteKDF(),
            inviteBlobCodec: codec,
            keystoreRoot: keystoreRoot,
            now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000) },
            identity: identity,
            generateMemberID: { "11111111-1111-4111-8111-111111111111" }
        )
    }

    private func sampleInvitePlaintext(orgID: String, teamKeyID: String, adminID: String,
                                       teamKeyBase64: String) -> InvitePlaintext {
        InvitePlaintext(
            teamKeyBase64: teamKeyBase64,
            teamKeyID: teamKeyID,
            orgID: orgID,
            orgName: "Acme Org",
            adminMemberID: adminID,
            adminDisplayName: "Admin",
            issuedAtMs: 1_699_999_900_000
        )
    }

    // MARK: - fetchInvite

    func testFetchInvite_Success_ReturnsBlobBytes() async throws {
        let blobBytes = Data([0x02] + (0..<140).map { _ in UInt8.random(in: 0...255) })
        let b64url = blobBytes.base64URLNoPad
        AcceptServiceMockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertTrue(req.url!.path.hasSuffix("/v1/invite/tok_abc123"))
            let body = """
            {"blob":"\(b64url)","expires_at_ms":1700086400000}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        }

        let svc = makeService()
        let blob = try await svc.fetchInvite(token: "tok_abc123")
        XCTAssertEqual(blob.bytes, blobBytes)
    }

    func testFetchInvite_404_MapsToInviteNotFound() async throws {
        AcceptServiceMockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil,
                                       headerFields: nil)!
            return (resp, nil)
        }
        let svc = makeService()
        do {
            _ = try await svc.fetchInvite(token: "tok_missing")
            XCTFail("expected inviteNotFound")
        } catch LeafError.inviteNotFound {
            // ok
        }
    }

    func testFetchInvite_TransportFailure_MapsToRelayUnreachable() async throws {
        AcceptServiceMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let svc = makeService()
        do {
            _ = try await svc.fetchInvite(token: "tok_offline")
            XCTFail("expected relayUnreachable")
        } catch LeafError.relayUnreachable(let reason) {
            XCTAssertEqual(reason, "transport")
        }
    }

    func testFetchInvite_EmptyToken_RejectedAsInvalidPayload() async throws {
        let svc = makeService()
        do {
            _ = try await svc.fetchInvite(token: "   ")
            XCTFail("expected invalidPayload")
        } catch LeafError.invalidPayload {
            // ok
        }
    }

    // MARK: - acceptInvite

    func testAcceptInvite_HappyPath_MaterializesRowsAndKeystoreFile() async throws {
        let inviteePriv = Curve25519.KeyAgreement.PrivateKey()
        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let adminPub = adminPriv.publicKey.rawRepresentation
        let blob = makeStubBlob(adminPubkey: adminPub)

        let teamKeyBytes = Data(repeating: 0x42, count: 32)
        let orgID = "00000000-0000-4000-8000-0000000000aa"
        let teamKeyID = "00000000-0000-4000-8000-0000000000bb"
        let adminID = "00000000-0000-4000-8000-0000000000cc"
        let codec = RecordingAcceptCodec()
        codec.stubPlaintext = sampleInvitePlaintext(orgID: orgID, teamKeyID: teamKeyID,
                                                    adminID: adminID,
                                                    teamKeyBase64: teamKeyBytes.base64EncodedString())

        let svc = makeAcceptService(codec: codec, identity: { inviteePriv })
        let accepted = try await svc.acceptInvite(blob: blob, otp: "123456", displayName: "  Bob  ")

        XCTAssertEqual(accepted.orgID, orgID)
        XCTAssertEqual(accepted.orgName, "Acme Org")
        XCTAssertEqual(accepted.teamKeyID, teamKeyID)
        XCTAssertEqual(accepted.selfMemberID, "11111111-1111-4111-8111-111111111111")

        // DB rows
        let org = try XCTUnwrap(db.listWorkspaces(includeLeft: true).first)
        XCTAssertEqual(org.id, orgID)
        XCTAssertEqual(org.name, "Acme Org")
        XCTAssertEqual(org.createdByMemberID, adminID)

        let members = try db.readTeamMembers(workspaceID: orgID)
        XCTAssertEqual(members.count, 2)
        let admin = try XCTUnwrap(members.first(where: { $0.id == adminID }))
        XCTAssertEqual(admin.role, .admin)
        XCTAssertEqual(admin.displayName, "Admin")
        XCTAssertEqual(admin.pubkeyHex,
                       adminPub.map { String(format: "%02x", $0) }.joined())
        let me = try XCTUnwrap(members.first(where: { $0.id == accepted.selfMemberID }))
        XCTAssertEqual(me.role, .member)
        XCTAssertEqual(me.displayName, "Bob")
        XCTAssertEqual(me.pubkeyHex,
                       inviteePriv.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined())

        let activeKey = try XCTUnwrap(db.readActiveTeamKey(workspaceID: orgID))
        XCTAssertEqual(activeKey.id, teamKeyID)

        // Keystore file — Track-5 S2 workspace-scoped sub-folder layout.
        let onDisk = try TeamKeystore.readTeamKey(workspaceID: orgID,
                                                  keyID: teamKeyID,
                                                  at: keystoreRoot)
        XCTAssertEqual(onDisk, teamKeyBytes)

        // Codec wired correctly
        XCTAssertEqual(codec.decodeCalls, 1)
        XCTAssertNotNil(codec.capturedWrapKey)
    }

    func testAcceptInvite_WrongOTP_LeavesDBUntouched() async throws {
        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let blob = makeStubBlob(adminPubkey: adminPriv.publicKey.rawRepresentation)

        let codec = RecordingAcceptCodec()
        codec.decodeError = LeafError.inviteOTPInvalid

        let svc = makeAcceptService(codec: codec, identity: { Curve25519.KeyAgreement.PrivateKey() })
        do {
            _ = try await svc.acceptInvite(blob: blob, otp: "000000", displayName: "Bob")
            XCTFail("expected inviteOTPInvalid")
        } catch LeafError.inviteOTPInvalid {
            // ok
        }

        XCTAssertNil(try db.listWorkspaces(includeLeft: true).first)
        // No keystore file written.
        let dir = try? FileManager.default.contentsOfDirectory(atPath: keystoreRoot.path)
        XCTAssertTrue(dir == nil || dir!.isEmpty,
                      "keystore root should be empty when decode fails before write")
    }

    func testAcceptInvite_WorkspaceAlreadyJoined_Refused() async throws {
        // Track-5 S2: under multi-workspace, "already accepted" means the
        // *same* workspace id is already present locally with `leftAt == nil`
        // (active membership). The codec must run first to surface the
        // workspace id from the blob, so we can no longer assert
        // `decodeCalls == 0` (preflight is now post-crypto).
        let existingMemberID = UUID().uuidString.lowercased()
        let workspaceID = "x"
        try db.upsertWorkspace(Workspace(id: workspaceID, name: "Existing",
                              createdAt: Date(timeIntervalSince1970: 1_699_000_000),
                              createdByMemberID: existingMemberID))

        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let blob = makeStubBlob(adminPubkey: adminPriv.publicKey.rawRepresentation)
        let codec = RecordingAcceptCodec()
        codec.stubPlaintext = sampleInvitePlaintext(orgID: workspaceID, teamKeyID: "y", adminID: "z",
                                                    teamKeyBase64: Data(repeating: 0, count: 32).base64EncodedString())

        let svc = makeAcceptService(codec: codec, identity: { Curve25519.KeyAgreement.PrivateKey() })
        do {
            _ = try await svc.acceptInvite(blob: blob, otp: "123456", displayName: "Bob")
            XCTFail("expected inviteAlreadyAccepted")
        } catch LeafError.inviteAlreadyAccepted {
            // ok
        }

        // Workspace row still the originally-seeded one (no membership added).
        let org = try XCTUnwrap(db.readWorkspace(id: workspaceID))
        XCTAssertEqual(org.id, workspaceID)
        XCTAssertEqual(try db.readTeamMembers(workspaceID: workspaceID).count, 0,
                       "No team_members rows should be added on duplicate-accept refusal")
    }

    func testAcceptInvite_ExistingLeftWorkspace_Rejoins() async throws {
        // Pre-seed a workspace that the user previously left (left_at_ms set).
        // The new invite carries the same workspaceID — InviteAcceptService
        // should clear left_at and insert a new self-member row, but NOT
        // re-insert the original admin row (PK collision).
        let workspaceID = "ws-rejoin"
        let originalAdminID = "admin-rejoin"
        try db.upsertWorkspace(Workspace(
            id: workspaceID,
            name: "RejoinedTeam",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
            createdByMemberID: originalAdminID
        ))
        try db.insertTeamMember(TeamMember(
            id: originalAdminID,
            workspaceID: workspaceID,
            role: .admin,
            pubkeyHex: String(repeating: "0", count: 64),
            displayName: "Admin",
            addedAt: Date(timeIntervalSince1970: 1_699_000_000),
            removedAt: nil
        ))
        try db.markWorkspaceLeft(workspaceID: workspaceID, at: Date(timeIntervalSince1970: 1_700_000_000))

        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let blob = makeStubBlob(adminPubkey: adminPriv.publicKey.rawRepresentation)
        let teamKeyBytes = Data(repeating: 0x55, count: 32)
        let codec = RecordingAcceptCodec()
        codec.stubPlaintext = sampleInvitePlaintext(
            orgID: workspaceID,
            teamKeyID: "rejoin-key",
            adminID: originalAdminID,
            teamKeyBase64: teamKeyBytes.base64EncodedString()
        )

        let svc = makeAcceptService(codec: codec, identity: { Curve25519.KeyAgreement.PrivateKey() })
        let accepted = try await svc.acceptInvite(blob: blob, otp: "123456", displayName: "Me Again")
        XCTAssertEqual(accepted.orgID, workspaceID)

        // Workspace.leftAt is now nil (rejoined).
        let after = try XCTUnwrap(db.readWorkspace(id: workspaceID))
        XCTAssertNil(after.leftAt, "Rejoin should clear left_at_ms")

        // Admin row preserved (no duplicate insert); self member added on top.
        let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: true)
        XCTAssertEqual(members.count, 2, "Original admin + new self member")
        XCTAssertNotNil(members.first(where: { $0.id == originalAdminID && $0.role == .admin }))
    }

    func testAcceptInvite_TruncatedBlob_ThrowsInviteBlobMalformed() async throws {
        // < 33 bytes — InviteBlobHeader.peek throws.
        let truncated = InviteBlob(bytes: Data([0x02] + Array(repeating: UInt8(0), count: 10)))
        let codec = RecordingAcceptCodec()
        let svc = makeAcceptService(codec: codec, identity: { Curve25519.KeyAgreement.PrivateKey() })

        do {
            _ = try await svc.acceptInvite(blob: truncated, otp: "123456", displayName: "Bob")
            XCTFail("expected inviteBlobMalformed")
        } catch LeafError.inviteBlobMalformed {
            // ok
        }
        XCTAssertEqual(codec.decodeCalls, 0)
    }

    func testAcceptInvite_BadTeamKeyBase64_ThrowsInviteBlobMalformed() async throws {
        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let blob = makeStubBlob(adminPubkey: adminPriv.publicKey.rawRepresentation)
        let codec = RecordingAcceptCodec()
        // Plaintext where teamKeyBase64 doesn't decode to 32 bytes.
        codec.stubPlaintext = InvitePlaintext(
            teamKeyBase64: "not-valid-base64!!!",
            teamKeyID: "kid",
            orgID: "oid",
            orgName: "Acme",
            adminMemberID: "aid",
            adminDisplayName: "Admin",
            issuedAtMs: 1_700_000_000_000
        )

        let svc = makeAcceptService(codec: codec, identity: { Curve25519.KeyAgreement.PrivateKey() })
        do {
            _ = try await svc.acceptInvite(blob: blob, otp: "123456", displayName: "Bob")
            XCTFail("expected inviteBlobMalformed")
        } catch LeafError.inviteBlobMalformed {
            // ok
        }
        XCTAssertNil(try db.listWorkspaces(includeLeft: true).first)
    }

    func testAcceptInvite_EmptyDisplayName_RejectedAsInvalidPayload() async throws {
        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let blob = makeStubBlob(adminPubkey: adminPriv.publicKey.rawRepresentation)
        let codec = RecordingAcceptCodec()
        let svc = makeAcceptService(codec: codec, identity: { Curve25519.KeyAgreement.PrivateKey() })

        do {
            _ = try await svc.acceptInvite(blob: blob, otp: "123456", displayName: "   ")
            XCTFail("expected invalidPayload")
        } catch LeafError.invalidPayload {
            // ok
        }
        XCTAssertEqual(codec.decodeCalls, 0)
    }

    // MARK: - Phase 5.5.B InviteURL overload

    func testFetchInvite_URL_ParsesAndDelegates() async throws {
        let blobBytes = Data([0x02] + (0..<140).map { _ in UInt8.random(in: 0...255) })
        let b64url = blobBytes.base64URLNoPad
        AcceptServiceMockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertTrue(req.url!.path.hasSuffix("/v1/invite/aBc012XyZ_KJI98hgFEdcBA5678901ab"))
            let body = """
            {"blob":"\(b64url)","expires_at_ms":1700086400000}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body)
        }
        let svc = makeService()
        let url = URL(string: "leaf://invite/aBc012XyZ_KJI98hgFEdcBA5678901ab#654321")!
        let result = try await svc.fetchInvite(inviteURL: url)
        XCTAssertEqual(result.blob.bytes, blobBytes)
        XCTAssertEqual(result.otp, "654321")
    }

    func testFetchInvite_URL_MalformedThrowsLeafError() async throws {
        let svc = makeService()
        do {
            _ = try await svc.fetchInvite(inviteURL: URL(string: "https://wrong/scheme")!)
            XCTFail("expected throw")
        } catch LeafError.inviteURLMalformed {
            // expected
        }
    }

    func testFetchInvite_URL_ConsumedRelayMapsToInviteAlreadyConsumed() async throws {
        AcceptServiceMockURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil,
                                       headerFields: nil)!
            return (resp, nil)
        }
        let svc = makeService()
        let url = URL(string: "leaf://invite/aBc012XyZ_KJI98hgFEdcBA5678901ab#000000")!
        do {
            _ = try await svc.fetchInvite(inviteURL: url)
            XCTFail("expected throw")
        } catch LeafError.inviteAlreadyConsumed {
            // expected — overload remaps inviteNotFound → inviteAlreadyConsumed для UX clarity
        }
    }
}
