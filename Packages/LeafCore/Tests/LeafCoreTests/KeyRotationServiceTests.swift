import XCTest
import Foundation
import CryptoKit
@testable import LeafCore

/// Phase 5.3.D — `KeyRotationService` admin orchestrator tests.
final class KeyRotationServiceTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!
    private var db: LeafCore.Database!
    private var relayClient: RelayClient!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-keyrotservice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KeyRotationServiceMockURLProtocol.self]
        relayClient = RelayClient(
            baseURL: URL(string: "https://test.example.com")!,
            urlSession: URLSession(configuration: config)
        )
    }

    override func tearDown() async throws {
        KeyRotationServiceMockURLProtocol.handler = nil
        db = nil
        relayClient = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeDate(_ epochMs: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000.0)
    }

    private func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Inserts org with self-admin + 2 peer members using real X25519 keypairs
    /// (so ECDH in performRotation succeeds). Returns the keypairs and prior teamKey
    /// for moat/E2E paths. Default IDs: org="org1", self="self-mem", peerA="peer-a",
    /// peerB="peer-b", priorKey="00000000-0000-0000-0000-000000000000".
    @discardableResult
    private func insertTeamFixture(
        orgID: String = "org1",
        selfMemberID: String = "self-mem",
        priorKeyID: String = "00000000-0000-0000-0000-000000000000"
    ) throws -> (
        adminPriv: Curve25519.KeyAgreement.PrivateKey,
        peerAPriv: Curve25519.KeyAgreement.PrivateKey,
        peerBPriv: Curve25519.KeyAgreement.PrivateKey,
        priorTeamKey: Data
    ) {
        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let peerAPriv = Curve25519.KeyAgreement.PrivateKey()
        let peerBPriv = Curve25519.KeyAgreement.PrivateKey()

        let selfPubHex = hexEncode(adminPriv.publicKey.rawRepresentation)
        let peerAPubHex = hexEncode(peerAPriv.publicKey.rawRepresentation)
        let peerBPubHex = hexEncode(peerBPriv.publicKey.rawRepresentation)

        try db.upsertOrg(Org(id: orgID, name: "Test Org", createdAt: makeDate(1_700_000_000_000), createdByMemberID: selfMemberID))
        try db.insertTeamMember(TeamMember(
            id: selfMemberID, orgID: orgID, role: .admin,
            pubkeyHex: selfPubHex, displayName: "Self",
            addedAt: makeDate(1_700_000_000_000), removedAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: "peer-a", orgID: orgID, role: .member,
            pubkeyHex: peerAPubHex, displayName: "PeerA",
            addedAt: makeDate(1_700_000_000_500), removedAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: "peer-b", orgID: orgID, role: .member,
            pubkeyHex: peerBPubHex, displayName: "PeerB",
            addedAt: makeDate(1_700_000_000_600), removedAt: nil
        ))
        try db.insertTeamKey(TeamKey(
            id: priorKeyID,
            generatedAt: makeDate(1_700_000_000_000),
            deprecatedAt: nil,
            generatedByMemberID: selfMemberID
        ))

        let priorTeamKey = Data(repeating: 0xFF, count: 32)
        try FileManager.default.createDirectory(
            at: keystoreRoot.appendingPathComponent(TeamKeystore.teamKeysSubdir, isDirectory: true),
            withIntermediateDirectories: true
        )
        try TeamKeystore.writeTeamKey(priorTeamKey, id: priorKeyID, at: keystoreRoot)

        return (adminPriv, peerAPriv, peerBPriv, priorTeamKey)
    }

    private func makeService(
        adminPriv: Curve25519.KeyAgreement.PrivateKey,
        kdf: any RotationKDF = RecordingRotationKDF(),
        codec: any RotationBlobCodec = RecordingRotationBlobCodec(),
        nowMs: Int64 = 1_700_000_001_000,
        newKeyID: String = "11111111-1111-1111-1111-111111111111"
    ) -> KeyRotationService {
        KeyRotationService(
            database: db,
            relayClient: relayClient,
            rotationKDF: kdf,
            rotationBlobCodec: codec,
            keystoreRoot: keystoreRoot,
            now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0) },
            randomBytes: { count in Data(repeating: 0xEE, count: count) },
            randomUUID: { newKeyID },
            identity: { adminPriv }
        )
    }

    // MARK: - Scaffold

    func testInitConstructs() {
        let svc = KeyRotationService(
            database: db,
            relayClient: relayClient,
            rotationKDF: UnimplementedRotationKDF(),
            rotationBlobCodec: UnimplementedRotationBlobCodec(),
            keystoreRoot: keystoreRoot
        )
        _ = svc  // just constructable
    }

    // MARK: - performRotation (via TEMP removeMember wrapper)

    func testPerformRotation_HappyPath_ComposesBlobsForBothPeers() async throws {
        let pubs = try insertTeamFixture()
        let kdf = RecordingRotationKDF()
        let codec = RecordingRotationBlobCodec()
        let svc = makeService(adminPriv: pubs.adminPriv, kdf: kdf, codec: codec)

        let outcome = try await svc.removeMember(memberID: "peer-b")

        // 2 outbox rows (1 .rotation peer-a + 1 .tombstone peer-b)
        XCTAssertEqual(outcome.totalCount, 2)
        XCTAssertEqual(codec.encodedPlaintexts.count, 2)
        // KDF called only for .rotation (peer-a). Tombstone uses raw prior teamKey.
        XCTAssertEqual(kdf.calls.count, 1)

        // DB state
        XCTAssertEqual(try db.readActiveTeamKey()?.id, "11111111-1111-1111-1111-111111111111")
        let priorKey = try db.readTeamKey(byID: "00000000-0000-0000-0000-000000000000")
        XCTAssertNotNil(priorKey?.deprecatedAt)
        let peerB = try db.readTeamMembers(orgID: "org1", includeRemoved: true)
            .first(where: { $0.id == "peer-b" })
        XCTAssertNotNil(peerB?.removedAt)

        // Outbox
        let unposted = try db.readUnpostedRotationOutboxRows()
        XCTAssertEqual(unposted.count, 2)
    }

    func testPerformRotation_TombstoneShape() async throws {
        let pubs = try insertTeamFixture()
        let codec = RecordingRotationBlobCodec()
        let svc = makeService(adminPriv: pubs.adminPriv, codec: codec)

        _ = try await svc.removeMember(memberID: "peer-b")

        XCTAssertEqual(codec.encodedPlaintexts.count, 2)

        let tombstone = codec.encodedPlaintexts.first(where: { $0.0.kind == .tombstone })
        XCTAssertNotNil(tombstone)
        XCTAssertEqual(tombstone?.0.removedMemberID, "peer-b")
        XCTAssertEqual(tombstone?.0.newKeyID, tombstone?.0.priorKeyID)
        XCTAssertEqual(tombstone?.0.newTeamKeyBase64, "")

        let rotation = codec.encodedPlaintexts.first(where: { $0.0.kind == .rotation })
        XCTAssertNotNil(rotation)
        XCTAssertNil(rotation?.0.removedMemberID)
        XCTAssertNotEqual(rotation?.0.newKeyID, rotation?.0.priorKeyID)
    }

    func testPerformRotation_FailsOnSelfRemoval() async throws {
        let pubs = try insertTeamFixture()
        let svc = makeService(adminPriv: pubs.adminPriv)

        do {
            _ = try await svc.removeMember(memberID: "self-mem")
            XCTFail("Expected throw")
        } catch let err as LeafError {
            if case .cannotRemoveSelfFromTeam = err {} else {
                XCTFail("Expected .cannotRemoveSelfFromTeam, got \(err)")
            }
        }
    }

    func testPerformRotation_FailsOnMissingMember() async throws {
        let pubs = try insertTeamFixture()
        let svc = makeService(adminPriv: pubs.adminPriv)

        do {
            _ = try await svc.removeMember(memberID: "ghost-mem")
            XCTFail("Expected throw")
        } catch let err as LeafError {
            if case .invalidPayload = err {} else {
                XCTFail("Expected .invalidPayload, got \(err)")
            }
        }
    }

    func testPerformRotation_FailsOnAlreadyRemovedMember() async throws {
        let pubs = try insertTeamFixture()
        try db.markTeamMemberRemoved(memberID: "peer-b", at: makeDate(1_700_000_000_900))
        let svc = makeService(adminPriv: pubs.adminPriv)

        do {
            _ = try await svc.removeMember(memberID: "peer-b")
            XCTFail("Expected throw")
        } catch let err as LeafError {
            if case .invalidPayload = err {} else {
                XCTFail("Expected .invalidPayload, got \(err)")
            }
        }
    }

    func testPerformRotation_FailsOnNoOrg() async throws {
        // Empty DB — no org row.
        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let svc = makeService(adminPriv: adminPriv)

        do {
            _ = try await svc.removeMember(memberID: "any-id")
            XCTFail("Expected throw")
        } catch let err as LeafError {
            if case .invalidPayload = err {} else {
                XCTFail("Expected .invalidPayload, got \(err)")
            }
        }
    }

    func testPerformRotation_FailsOnNoActiveTeamKey() async throws {
        // Org + members but no active team_keys row.
        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let selfPubHex = hexEncode(adminPriv.publicKey.rawRepresentation)
        let peerPriv = Curve25519.KeyAgreement.PrivateKey()
        let peerPubHex = hexEncode(peerPriv.publicKey.rawRepresentation)

        try db.upsertOrg(Org(id: "org1", name: "Test Org", createdAt: makeDate(1_700_000_000_000), createdByMemberID: "self-mem"))
        try db.insertTeamMember(TeamMember(
            id: "self-mem", orgID: "org1", role: .admin,
            pubkeyHex: selfPubHex, displayName: "Self",
            addedAt: makeDate(1_700_000_000_000), removedAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: "peer-b", orgID: "org1", role: .member,
            pubkeyHex: peerPubHex, displayName: "PeerB",
            addedAt: makeDate(1_700_000_000_500), removedAt: nil
        ))
        let svc = makeService(adminPriv: adminPriv)

        do {
            _ = try await svc.removeMember(memberID: "peer-b")
            XCTFail("Expected throw")
        } catch let err as LeafError {
            if case .invalidPayload = err {} else {
                XCTFail("Expected .invalidPayload, got \(err)")
            }
        }
    }
}

// MARK: - Recording doubles

final class RecordingRotationKDF: RotationKDF, @unchecked Sendable {
    nonisolated(unsafe) var stubKey = SymmetricKey(size: .bits256)
    nonisolated(unsafe) var calls: [(SharedSecret, Data)] = []

    func deriveWrapKey(sharedSecret: SharedSecret, newKeyID: Data) throws -> SymmetricKey {
        calls.append((sharedSecret, newKeyID))
        return stubKey
    }
}

final class RecordingRotationBlobCodec: RotationBlobCodec, @unchecked Sendable {
    /// Captured (plaintext, recipientPubkey) per encode call.
    nonisolated(unsafe) var encodedPlaintexts: [(RotationPlaintext, Data)] = []

    func encode(_ plaintext: RotationPlaintext, recipientPubkey: Data, wrapKey: SymmetricKey) throws -> RotationBlob {
        encodedPlaintexts.append((plaintext, recipientPubkey))
        // Deterministic stub blob: 1B ver + 16B prior + 16B new + 32B recipient + 12B nonce + 1B ct + 16B tag = 94B
        var bytes = Data([0x03])
        bytes.append(Data(repeating: 0xAA, count: 16))
        bytes.append(Data(repeating: 0xBB, count: 16))
        bytes.append(recipientPubkey)
        bytes.append(Data(repeating: 0xCC, count: 12))
        bytes.append(Data([UInt8(encodedPlaintexts.count & 0xFF)]))
        bytes.append(Data(repeating: 0xDD, count: 16))
        return RotationBlob(bytes: bytes)
    }

    func decode(_ blob: RotationBlob, wrapKey: SymmetricKey) throws -> RotationPlaintext {
        throw LeafError.notImplemented
    }
}

// MARK: - Mock URLProtocol (file-local)

final class KeyRotationServiceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body = request.httpBody ?? Data()
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
}
