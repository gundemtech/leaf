import XCTest
import Foundation
import CryptoKit
@testable import LeafCore

final class RotationFetchServiceTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!
    private var db: LeafCore.Database!
    private var relayClient: RelayClient!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-rotfetchsvc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        db = try LeafCore.Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RotationFetchServiceMockURLProtocol.self]
        relayClient = RelayClient(
            baseURL: URL(string: "https://test.example.com")!,
            urlSession: URLSession(configuration: config)
        )
    }

    override func tearDown() async throws {
        RotationFetchServiceMockURLProtocol.handler = nil
        RotationFetchServiceMockURLProtocol.networkError = nil
        RotationFetchServiceMockURLProtocol.lastRequest = nil
        db = nil
        relayClient = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Scaffold

    func testInitConstructs() {
        let svc = RotationFetchService(
            database: db,
            relayClient: relayClient,
            rotationKDF: UnimplementedRotationKDF(),
            rotationBlobCodec: UnimplementedRotationBlobCodec(),
            keystoreRoot: keystoreRoot
        )
        _ = svc  // just constructable
    }

    // MARK: - Helpers

    fileprivate func makeService(
        kdf: any RotationKDF = UnimplementedRotationKDF(),
        codec: any RotationBlobCodec = UnimplementedRotationBlobCodec(),
        nowMs: Int64 = 1_700_000_001_000,
        identityPriv: Curve25519.KeyAgreement.PrivateKey? = nil
    ) -> RotationFetchService {
        // Curve25519 PrivateKey isn't Sendable; capture raw bytes (Data) and reconstruct.
        let identityClosure: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)?
        if let priv = identityPriv {
            let rawBytes = priv.rawRepresentation
            identityClosure = { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawBytes) }
        } else {
            identityClosure = nil
        }
        return RotationFetchService(
            database: db,
            relayClient: relayClient,
            rotationKDF: kdf,
            rotationBlobCodec: codec,
            keystoreRoot: keystoreRoot,
            now: { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0) },
            identity: identityClosure
        )
    }

    fileprivate func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    fileprivate func makeDate(_ epochMs: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000.0)
    }

    /// Inserts org + admin (other peer) + self (member running tick) + 3rd peer +
    /// active teamKey + keystore (identity x25519 priv + prior teamKey).
    /// Returns identity priv (so makeService can use it deterministically).
    @discardableResult
    fileprivate func insertTeamFixture(
        orgID: String = "org1",
        selfMemberID: String = "self-mem",
        priorKeyID: String = "00000000-0000-0000-0000-000000000000"
    ) throws -> (
        selfPriv: Curve25519.KeyAgreement.PrivateKey,
        adminPriv: Curve25519.KeyAgreement.PrivateKey,
        peerPriv: Curve25519.KeyAgreement.PrivateKey,
        priorTeamKey: Data
    ) {
        let selfPriv = Curve25519.KeyAgreement.PrivateKey()
        let adminPriv = Curve25519.KeyAgreement.PrivateKey()
        let peerPriv = Curve25519.KeyAgreement.PrivateKey()

        let selfPubHex = hexEncode(selfPriv.publicKey.rawRepresentation)
        let adminPubHex = hexEncode(adminPriv.publicKey.rawRepresentation)
        let peerPubHex = hexEncode(peerPriv.publicKey.rawRepresentation)

        try db.upsertOrg(Org(id: orgID, name: "Test Org",
                             createdAt: makeDate(1_700_000_000_000),
                             createdByMemberID: "admin-mem"))
        try db.insertTeamMember(TeamMember(
            id: "admin-mem", orgID: orgID, role: .admin,
            pubkeyHex: adminPubHex, displayName: "Admin",
            addedAt: makeDate(1_700_000_000_000), removedAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: selfMemberID, orgID: orgID, role: .member,
            pubkeyHex: selfPubHex, displayName: "Self",
            addedAt: makeDate(1_700_000_000_500), removedAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: "peer-other", orgID: orgID, role: .member,
            pubkeyHex: peerPubHex, displayName: "PeerOther",
            addedAt: makeDate(1_700_000_000_600), removedAt: nil
        ))
        try db.insertTeamKey(TeamKey(
            id: priorKeyID,
            generatedAt: makeDate(1_700_000_000_000),
            deprecatedAt: nil,
            generatedByMemberID: "admin-mem"
        ))

        let priorTeamKey = Data(repeating: 0xFF, count: 32)
        try FileManager.default.createDirectory(
            at: keystoreRoot.appendingPathComponent(TeamKeystore.teamKeysSubdir, isDirectory: true),
            withIntermediateDirectories: true
        )
        try TeamKeystore.writeX25519Private(selfPriv.rawRepresentation, at: keystoreRoot)
        try TeamKeystore.writeTeamKey(priorTeamKey, id: priorKeyID, at: keystoreRoot)

        return (selfPriv, adminPriv, peerPriv, priorTeamKey)
    }

    fileprivate static func stubRelay200Empty(_ request: URLRequest, _ body: Data) throws -> (HTTPURLResponse, Data?) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        return (resp, "{\"rotations\":[]}".data(using: .utf8)!)
    }

    // MARK: - Preflight + drain

    func testNoOrg_ReturnsEmpty() async throws {
        // Empty DB; no fixture.
        RotationFetchServiceMockURLProtocol.handler = { req, body in try Self.stubRelay200Empty(req, body) }
        let svc = makeService()
        let outcome = await svc.tick()
        XCTAssertEqual(outcome, .empty)
        XCTAssertNil(RotationFetchServiceMockURLProtocol.lastRequest, "Should not call relay if no org")
    }

    func testEmptyMailbox_ReturnsEmpty_NoAck() async throws {
        let pubs = try insertTeamFixture()
        RotationFetchServiceMockURLProtocol.handler = { req, body in try Self.stubRelay200Empty(req, body) }
        let svc = makeService(identityPriv: pubs.selfPriv)
        let outcome = await svc.tick()
        XCTAssertEqual(outcome, .empty)
        XCTAssertEqual(RotationFetchServiceMockURLProtocol.lastRequest?.httpMethod, "GET")
    }

    func testRelayTransportError_ReturnsEmpty() async throws {
        let pubs = try insertTeamFixture()
        RotationFetchServiceMockURLProtocol.networkError = URLError(.notConnectedToInternet)
        defer { RotationFetchServiceMockURLProtocol.networkError = nil }
        let svc = makeService(identityPriv: pubs.selfPriv)
        let outcome = await svc.tick()
        XCTAssertEqual(outcome, .empty)
    }

    func testPeekFails_Skips_NoAck() async throws {
        let pubs = try insertTeamFixture()
        // Return a blob that's too short for peek (< 65 bytes).
        let shortBlob = Data(repeating: 0x03, count: 10).base64URLNoPad
        let body = """
            {"rotations":[{"rotation_id":"abcdef0123456789abcdef0123456789",\
            "blob":"\(shortBlob)","expires_at_ms":1700000086400000}]}
            """
        RotationFetchServiceMockURLProtocol.handler = { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }
        let svc = makeService(identityPriv: pubs.selfPriv)
        let outcome = await svc.tick()
        XCTAssertEqual(outcome.fetched, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertEqual(outcome.tombstoneApplied, 0)
        // No DELETE request expected — we did NOT ack.
        XCTAssertEqual(RotationFetchServiceMockURLProtocol.lastRequest?.httpMethod, "GET",
                       "Last request should be GET, not DELETE")
    }
}

// MARK: - Mock URLProtocol (file-local)

final class RotationFetchServiceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var networkError: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let err = Self.networkError {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Self.lastRequest = request
        do {
            let (resp, data) = try handler(request, Data())
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data = data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
