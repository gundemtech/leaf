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
        let org = try XCTUnwrap(db.readOrg())
        XCTAssertEqual(org.id, orgID)
        XCTAssertEqual(org.name, "Acme Org")
        XCTAssertEqual(org.createdByMemberID, adminID)

        let members = try db.readTeamMembers(orgID: orgID)
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

        let activeKey = try XCTUnwrap(db.readActiveTeamKey())
        XCTAssertEqual(activeKey.id, teamKeyID)

        // Keystore file
        let onDisk = try TeamKeystore.readTeamKey(id: teamKeyID, at: keystoreRoot)
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

        XCTAssertNil(try db.readOrg())
        // No keystore file written.
        let dir = try? FileManager.default.contentsOfDirectory(atPath: keystoreRoot.path)
        XCTAssertTrue(dir == nil || dir!.isEmpty,
                      "keystore root should be empty when decode fails before write")
    }

    func testAcceptInvite_OrgAlreadyExists_RefusedBeforeCrypto() async throws {
        // Pre-seed an org row.
        let existingOrgID = UUID().uuidString.lowercased()
        let existingMemberID = UUID().uuidString.lowercased()
        try db.upsertOrg(Org(id: existingOrgID, name: "Existing",
                              createdAt: Date(timeIntervalSince1970: 1_699_000_000),
                              createdByMemberID: existingMemberID))

        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let blob = makeStubBlob(adminPubkey: adminPriv.publicKey.rawRepresentation)
        let codec = RecordingAcceptCodec()
        codec.stubPlaintext = sampleInvitePlaintext(orgID: "x", teamKeyID: "y", adminID: "z",
                                                    teamKeyBase64: Data(repeating: 0, count: 32).base64EncodedString())

        let svc = makeAcceptService(codec: codec, identity: { Curve25519.KeyAgreement.PrivateKey() })
        do {
            _ = try await svc.acceptInvite(blob: blob, otp: "123456", displayName: "Bob")
            XCTFail("expected inviteAlreadyAccepted")
        } catch LeafError.inviteAlreadyAccepted {
            // ok
        }

        // Codec must NOT have been called — preflight rejected.
        XCTAssertEqual(codec.decodeCalls, 0)
        // Original org row untouched.
        let org = try XCTUnwrap(db.readOrg())
        XCTAssertEqual(org.id, existingOrgID)
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
        XCTAssertNil(try db.readOrg())
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
}
