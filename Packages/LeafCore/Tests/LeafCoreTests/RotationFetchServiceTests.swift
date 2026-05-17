import CryptoKit
import Foundation
import XCTest

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
        RotationFetchServiceMockURLProtocol.requestLog = []
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

        try db.upsertOrg(
            Org(
                id: orgID, name: "Test Org",
                createdAt: makeDate(1_700_000_000_000),
                createdByMemberID: "admin-mem"))
        try db.insertTeamMember(
            TeamMember(
                id: "admin-mem", orgID: orgID, role: .admin,
                pubkeyHex: adminPubHex, displayName: "Admin",
                addedAt: makeDate(1_700_000_000_000), removedAt: nil
            ))
        try db.insertTeamMember(
            TeamMember(
                id: selfMemberID, orgID: orgID, role: .member,
                pubkeyHex: selfPubHex, displayName: "Self",
                addedAt: makeDate(1_700_000_000_500), removedAt: nil
            ))
        try db.insertTeamMember(
            TeamMember(
                id: "peer-other", orgID: orgID, role: .member,
                pubkeyHex: peerPubHex, displayName: "PeerOther",
                addedAt: makeDate(1_700_000_000_600), removedAt: nil
            ))
        try db.insertTeamKey(
            TeamKey(
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
        let resp = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
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
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
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
        XCTAssertEqual(RotationFetchServiceMockURLProtocol.ackCount(), 0)
    }

    // MARK: - Tombstone path

    /// Builds a stub tombstone blob bytes: header bytes (95B real layout so peek works)
    /// + Recording codec returns the matching plaintext. Caller passes returned codec
    /// instance into makeService().
    fileprivate func makeTombstoneBlob(
        priorKeyID: String,
        removedMemberID: String,
        wrapKey: SymmetricKey,
        recipientPubkey: Data
    ) throws -> (bytes: Data, codec: TombstoneRecordingCodec) {
        let codec = TombstoneRecordingCodec()
        codec.wrapKeyExpected = wrapKey
        codec.tombstoneFor = TombstoneRecordingCodec.TombstoneSpec(
            priorKeyID: priorKeyID, newKeyID: priorKeyID, removedMemberID: removedMemberID
        )
        let plaintext = RotationPlaintext(
            kind: .tombstone, newTeamKeyBase64: "",
            newKeyID: priorKeyID, priorKeyID: priorKeyID,
            generatedAtMs: 1_700_000_000_500, removedMemberID: removedMemberID
        )
        let blob = try codec.encode(plaintext, recipientPubkey: recipientPubkey, wrapKey: wrapKey)
        return (blob.bytes, codec)
    }

    /// Mounts a relay handler that returns a single fetched blob on GET and 204 on DELETE.
    fileprivate static func mountSingleBlobHandler(
        blobBytes: Data, rotationID: String = "abcdef0123456789abcdef0123456789"
    ) {
        let blobB64 = blobBytes.base64URLNoPad
        let body = """
            {"rotations":[{"rotation_id":"\(rotationID)",\
            "blob":"\(blobB64)","expires_at_ms":1700000086400000}]}
            """
        RotationFetchServiceMockURLProtocol.handler = { req, _ in
            if req.httpMethod == "DELETE" {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                return (resp, nil)
            }
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }
    }

    func testTombstoneHappyPath_MarksSelfRemoved_AndAcks() async throws {
        let pubs = try insertTeamFixture()
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let wrapKey = SymmetricKey(data: pubs.priorTeamKey)

        let (blobBytes, codec) = try makeTombstoneBlob(
            priorKeyID: priorKeyID,
            removedMemberID: "self-mem",
            wrapKey: wrapKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )

        Self.mountSingleBlobHandler(blobBytes: blobBytes)

        let svc = makeService(codec: codec, identityPriv: pubs.selfPriv)

        let outcome = await svc.tick()

        XCTAssertEqual(outcome.fetched, 1)
        XCTAssertEqual(outcome.tombstoneApplied, 1)
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(RotationFetchServiceMockURLProtocol.ackCount(), 1)

        // DB: self should be marked removed.
        let allMembers = try db.readTeamMembers(orgID: "org1", includeRemoved: true)
        let selfMember = allMembers.first(where: { $0.id == "self-mem" })
        XCTAssertNotNil(selfMember?.removedAt)
    }

    func testTombstoneMisroutedToOtherMember_DoesNotMarkSelf_NoAck() async throws {
        let pubs = try insertTeamFixture()
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let wrapKey = SymmetricKey(data: pubs.priorTeamKey)

        // removedMemberID points to "peer-other", NOT self.
        let (blobBytes, codec) = try makeTombstoneBlob(
            priorKeyID: priorKeyID,
            removedMemberID: "peer-other",
            wrapKey: wrapKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )
        Self.mountSingleBlobHandler(blobBytes: blobBytes)

        let svc = makeService(codec: codec, identityPriv: pubs.selfPriv)
        let outcome = await svc.tick()

        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.tombstoneApplied, 0)
        XCTAssertEqual(
            RotationFetchServiceMockURLProtocol.ackCount(), 0,
            "Mis-routed tombstone must NOT be acked")

        let allMembers = try db.readTeamMembers(orgID: "org1", includeRemoved: true)
        let selfMember = allMembers.first(where: { $0.id == "self-mem" })
        XCTAssertNil(selfMember?.removedAt)
    }

    func testTombstoneMissingPriorTeamKeyInKeystore_Skips_NoAck() async throws {
        let pubs = try insertTeamFixture()
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let wrapKey = SymmetricKey(data: pubs.priorTeamKey)

        let (blobBytes, codec) = try makeTombstoneBlob(
            priorKeyID: priorKeyID,
            removedMemberID: "self-mem",
            wrapKey: wrapKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )
        // Delete keystore prior teamKey file (simulate missing/corrupted).
        try FileManager.default.removeItem(
            at: keystoreRoot.appendingPathComponent(TeamKeystore.teamKeysSubdir, isDirectory: true)
                .appendingPathComponent("\(priorKeyID).key", isDirectory: false)
        )

        Self.mountSingleBlobHandler(blobBytes: blobBytes)

        let svc = makeService(codec: codec, identityPriv: pubs.selfPriv)
        let outcome = await svc.tick()

        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.tombstoneApplied, 0)
        XCTAssertEqual(RotationFetchServiceMockURLProtocol.ackCount(), 0)
    }

    func testTombstoneWrongKindPostDecrypt_Skips() async throws {
        // Codec returns .rotation kind despite peek discriminator (priorKeyID == newKeyID
        // → tombstone path). Defensive cross-field check should reject.
        let pubs = try insertTeamFixture()
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let wrapKey = SymmetricKey(data: pubs.priorTeamKey)

        let codec = TombstoneRecordingCodec()
        codec.wrapKeyExpected = wrapKey
        codec.tombstoneFor = TombstoneRecordingCodec.TombstoneSpec(
            priorKeyID: priorKeyID, newKeyID: priorKeyID, removedMemberID: "self-mem"
        )
        codec.forceKindOnDecode = .rotation
        let plaintext = RotationPlaintext(
            kind: .tombstone, newTeamKeyBase64: "",
            newKeyID: priorKeyID, priorKeyID: priorKeyID,
            generatedAtMs: 1_700_000_000_500, removedMemberID: "self-mem"
        )
        let rotationBlob = try codec.encode(
            plaintext,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation,
            wrapKey: wrapKey)
        Self.mountSingleBlobHandler(blobBytes: rotationBlob.bytes)

        let svc = makeService(codec: codec, identityPriv: pubs.selfPriv)
        let outcome = await svc.tick()

        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.tombstoneApplied, 0)
        XCTAssertEqual(RotationFetchServiceMockURLProtocol.ackCount(), 0)
    }

    // MARK: - Rotation path

    fileprivate func makeRotationBlob(
        priorKeyID: String, newKeyID: String,
        newTeamKeyBytes: Data,
        recipientPubkey: Data
    ) throws -> (bytes: Data, codec: RotationRecordingCodec) {
        let codec = RotationRecordingCodec()
        codec.installSpec = RotationRecordingCodec.RotationSpec(
            priorKeyID: priorKeyID,
            newKeyID: newKeyID,
            newTeamKeyBase64: newTeamKeyBytes.base64EncodedString()
        )
        let plaintext = RotationPlaintext(
            kind: .rotation,
            newTeamKeyBase64: newTeamKeyBytes.base64EncodedString(),
            newKeyID: newKeyID, priorKeyID: priorKeyID,
            generatedAtMs: 1_700_000_000_500, removedMemberID: nil
        )
        let blob = try codec.encode(
            plaintext, recipientPubkey: recipientPubkey,
            wrapKey: SymmetricKey(size: .bits256))
        return (blob.bytes, codec)
    }

    func testRotationHappyPathSingleAdmin_Installs_AcksRelay() async throws {
        let pubs = try insertTeamFixture()
        let newKeyID = "11111111-1111-1111-1111-111111111111"
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let newTeamKey = Data(repeating: 0xAB, count: 32)

        let (blobBytes, codec) = try makeRotationBlob(
            priorKeyID: priorKeyID, newKeyID: newKeyID,
            newTeamKeyBytes: newTeamKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )
        let stubKey = SymmetricKey(size: .bits256)
        codec.wrapKeyExpected = stubKey

        let kdf = RecordingKDF()
        kdf.stubKey = stubKey

        Self.mountSingleBlobHandler(blobBytes: blobBytes)

        let svc = makeService(kdf: kdf, codec: codec, identityPriv: pubs.selfPriv)

        let outcome = await svc.tick()

        XCTAssertEqual(outcome.fetched, 1)
        XCTAssertEqual(outcome.installed, 1)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(RotationFetchServiceMockURLProtocol.ackCount(), 1)

        XCTAssertEqual(try db.readActiveTeamKey()?.id, newKeyID)
        let prior = try db.readTeamKey(byID: priorKeyID)
        XCTAssertNotNil(prior?.deprecatedAt)

        let storedNew = try TeamKeystore.readTeamKey(id: newKeyID, at: keystoreRoot)
        XCTAssertEqual(storedNew, newTeamKey)
    }

    func testRotationDuplicateInstall_Idempotent() async throws {
        let pubs = try insertTeamFixture()
        let newKeyID = "11111111-1111-1111-1111-111111111111"
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let newTeamKey = Data(repeating: 0xAB, count: 32)

        let (blobBytes, codec) = try makeRotationBlob(
            priorKeyID: priorKeyID, newKeyID: newKeyID,
            newTeamKeyBytes: newTeamKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )
        let stubKey = SymmetricKey(size: .bits256)
        codec.wrapKeyExpected = stubKey

        let kdf = RecordingKDF()
        kdf.stubKey = stubKey

        Self.mountSingleBlobHandler(blobBytes: blobBytes)

        let svc = makeService(kdf: kdf, codec: codec, identityPriv: pubs.selfPriv)

        // First call — installs.
        _ = await svc.tick()
        // Second call — same blob (relay still has it); install path runs idempotently
        // via insertTeamKeyIfAbsent (no-op) + deprecateTeamKey (already deprecated, no-op).
        let outcome2 = await svc.tick()

        XCTAssertEqual(outcome2.fetched, 1)
        // Idempotent install reported as success (insertIfAbsent no-op + deprecate idempotent).
        XCTAssertEqual(outcome2.installed, 1)

        // Active key unchanged (still newKeyID).
        XCTAssertEqual(try db.readActiveTeamKey()?.id, newKeyID)
    }

    /// Promotes `peer-other` (member) to `.admin` so iteration sees 2 admin candidates.
    fileprivate func promotePeerOtherToAdmin() throws {
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: """
                    UPDATE \(Schema.TeamMembers.tableName)
                    SET \(Schema.TeamMembers.role) = 'admin'
                    WHERE \(Schema.TeamMembers.id) = 'peer-other'
                    """)
        }
    }

    func testRotationHappyPathMultiAdmin_FirstWorks_DoesNotTrySecond() async throws {
        let pubs = try insertTeamFixture()
        try promotePeerOtherToAdmin()

        let newKeyID = "11111111-1111-1111-1111-111111111111"
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let newTeamKey = Data(repeating: 0xAB, count: 32)

        let (blobBytes, codec) = try makeRotationBlob(
            priorKeyID: priorKeyID, newKeyID: newKeyID,
            newTeamKeyBytes: newTeamKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )
        let stubKey = SymmetricKey(size: .bits256)
        codec.wrapKeyExpected = stubKey

        // First admin's KDF derive returns stubKey (codec accepts) → decode succeeds → break.
        let kdf = RecordingKDF()
        kdf.stubKey = stubKey

        Self.mountSingleBlobHandler(blobBytes: blobBytes)

        let svc = makeService(kdf: kdf, codec: codec, identityPriv: pubs.selfPriv)
        let outcome = await svc.tick()

        XCTAssertEqual(outcome.installed, 1)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(
            kdf.calls.count, 1, "Iteration must break after first admin succeeds; got \(kdf.calls.count) calls")
    }

    func testRotationHappyPathMultiAdmin_FirstFails_SecondWorks() async throws {
        let pubs = try insertTeamFixture()
        try promotePeerOtherToAdmin()

        let newKeyID = "11111111-1111-1111-1111-111111111111"
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let newTeamKey = Data(repeating: 0xAB, count: 32)

        let (blobBytes, codec) = try makeRotationBlob(
            priorKeyID: priorKeyID, newKeyID: newKeyID,
            newTeamKeyBytes: newTeamKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )

        // Codec accepts only the SECOND admin's derived key → first admin's
        // ECDH+HKDF produces wrong key (rejected by codec); second succeeds.
        let firstKey = SymmetricKey(size: .bits256)
        let secondKey = SymmetricKey(size: .bits256)
        codec.acceptedWrapKeys = [secondKey]

        let kdf = RecordingKDF()
        kdf.stubKeysSequence = [firstKey, secondKey]

        Self.mountSingleBlobHandler(blobBytes: blobBytes)

        let svc = makeService(kdf: kdf, codec: codec, identityPriv: pubs.selfPriv)
        let outcome = await svc.tick()

        XCTAssertEqual(outcome.installed, 1)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(
            kdf.calls.count, 2,
            "Iteration must try both admins (first rejects → second wins); got \(kdf.calls.count) calls")
        XCTAssertEqual(try db.readActiveTeamKey()?.id, newKeyID)
    }

    func testRotationAllAdminsFail_Skips_NoAck() async throws {
        let pubs = try insertTeamFixture()
        let newKeyID = "11111111-1111-1111-1111-111111111111"
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let newTeamKey = Data(repeating: 0xAB, count: 32)

        let (blobBytes, codec) = try makeRotationBlob(
            priorKeyID: priorKeyID, newKeyID: newKeyID,
            newTeamKeyBytes: newTeamKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )
        let stubKey = SymmetricKey(size: .bits256)
        codec.wrapKeyExpected = stubKey

        // KDF returns DIFFERENT key from stubKey; codec rejects.
        let kdf = RecordingKDF()
        kdf.stubKey = SymmetricKey(size: .bits256)  // != stubKey

        Self.mountSingleBlobHandler(blobBytes: blobBytes)

        let svc = makeService(kdf: kdf, codec: codec, identityPriv: pubs.selfPriv)

        let outcome = await svc.tick()
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.installed, 0)
        XCTAssertEqual(RotationFetchServiceMockURLProtocol.ackCount(), 0)

        XCTAssertEqual(try db.readActiveTeamKey()?.id, priorKeyID)
        XCTAssertNil(try db.readTeamKey(byID: newKeyID))
    }

    func testMultipleBlobsMixedOutcomes() async throws {
        let pubs = try insertTeamFixture()
        let priorKeyID = "00000000-0000-0000-0000-000000000000"
        let newKeyID = "11111111-1111-1111-1111-111111111111"
        let newTeamKey = Data(repeating: 0xAB, count: 32)

        let (rotBytes, rotCodec) = try makeRotationBlob(
            priorKeyID: priorKeyID, newKeyID: newKeyID, newTeamKeyBytes: newTeamKey,
            recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )
        let stubKey = SymmetricKey(size: .bits256)
        rotCodec.wrapKeyExpected = stubKey

        let tombKey = SymmetricKey(data: pubs.priorTeamKey)
        let (tombBytes, tombCodec) = try makeTombstoneBlob(
            priorKeyID: priorKeyID, removedMemberID: "self-mem",
            wrapKey: tombKey, recipientPubkey: pubs.selfPriv.publicKey.rawRepresentation
        )
        // Wait — running tombstone install will set self.removed_at_ms; that's fine
        // because we don't assert on self-state, only on counts + acks.

        // Bad/short blob.
        let badBytes = Data(repeating: 0x00, count: 5)

        let composite = CompositeCodec()
        composite.rotation = rotCodec
        composite.tombstone = tombCodec

        let kdf = RecordingKDF()
        kdf.stubKey = stubKey

        let body = """
            {"rotations":[\
            {"rotation_id":"a1","blob":"\(rotBytes.base64URLNoPad)","expires_at_ms":1700000086400000},\
            {"rotation_id":"a2","blob":"\(tombBytes.base64URLNoPad)","expires_at_ms":1700000086400000},\
            {"rotation_id":"a3","blob":"\(badBytes.base64URLNoPad)","expires_at_ms":1700000086400000}\
            ]}
            """
        RotationFetchServiceMockURLProtocol.handler = { req, _ in
            if req.httpMethod == "DELETE" {
                let resp = HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
                return (resp, nil)
            }
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            return (resp, body.data(using: .utf8)!)
        }

        let svc = makeService(kdf: kdf, codec: composite, identityPriv: pubs.selfPriv)

        let outcome = await svc.tick()
        XCTAssertEqual(outcome.fetched, 3)
        XCTAssertEqual(outcome.installed, 1)
        XCTAssertEqual(outcome.tombstoneApplied, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(
            RotationFetchServiceMockURLProtocol.ackCount(), 2,
            "Both happy paths acked; bad blob not acked")
    }
}

// MARK: - Recording codec for tombstone tests

final class TombstoneRecordingCodec: RotationBlobCodec, @unchecked Sendable {
    struct TombstoneSpec {
        let priorKeyID: String
        let newKeyID: String
        let removedMemberID: String
    }

    nonisolated(unsafe) var wrapKeyExpected: SymmetricKey?
    nonisolated(unsafe) var tombstoneFor: TombstoneSpec?
    /// If set, decode returns plaintext with this kind regardless of encoded blob.
    nonisolated(unsafe) var forceKindOnDecode: RotationKind?

    func encode(_ plaintext: RotationPlaintext, recipientPubkey: Data, wrapKey: SymmetricKey) throws -> RotationBlob {
        // Build a real RotationBlobHeader prefix so peek() works (exact field
        // composition is moat — see ProdRotationBlobCodec).
        var bytes = Data([0x03])
        let priorBytes = uuidBytes(plaintext.priorKeyID)
        let newBytes = uuidBytes(plaintext.newKeyID)
        bytes.append(priorBytes)
        bytes.append(newBytes)
        bytes.append(recipientPubkey)
        bytes.append(Data(repeating: 0xCC, count: 12))
        bytes.append(Data([0xEE]))
        bytes.append(Data(repeating: 0xDD, count: 16))
        return RotationBlob(bytes: bytes)
    }

    func decode(_ blob: RotationBlob, wrapKey: SymmetricKey) throws -> RotationPlaintext {
        if let expected = wrapKeyExpected,
            expected.withUnsafeBytes({ Data($0) }) != wrapKey.withUnsafeBytes({ Data($0) })
        {
            throw LeafError.rotationBlobMalformed
        }
        guard let spec = tombstoneFor else { throw LeafError.rotationBlobMalformed }
        return RotationPlaintext(
            kind: forceKindOnDecode ?? .tombstone,
            newTeamKeyBase64: "",
            newKeyID: spec.newKeyID,
            priorKeyID: spec.priorKeyID,
            generatedAtMs: 1_700_000_000_500,
            removedMemberID: spec.removedMemberID
        )
    }

    private func uuidBytes(_ uuidString: String) -> Data {
        guard let uuid = UUID(uuidString: uuidString) else { return Data(repeating: 0, count: 16) }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}

// MARK: - Recording KDF for rotation tests

final class RecordingKDF: RotationKDF, @unchecked Sendable {
    nonisolated(unsafe) var stubKey = SymmetricKey(size: .bits256)
    /// If set, deriveWrapKey returns sequenced keys per call (index 0 → first call,
    /// index 1 → second call, etc.). Falls back to `stubKey` once exhausted.
    /// Used by multi-admin iteration tests.
    nonisolated(unsafe) var stubKeysSequence: [SymmetricKey]?
    nonisolated(unsafe) var calls: [(SharedSecret, Data)] = []

    func deriveWrapKey(sharedSecret: SharedSecret, newKeyID: Data) throws -> SymmetricKey {
        calls.append((sharedSecret, newKeyID))
        if let seq = stubKeysSequence, calls.count <= seq.count {
            return seq[calls.count - 1]
        }
        return stubKey
    }
}

// MARK: - Recording rotation codec

final class RotationRecordingCodec: RotationBlobCodec, @unchecked Sendable {
    struct RotationSpec {
        let priorKeyID: String
        let newKeyID: String
        let newTeamKeyBase64: String
    }
    nonisolated(unsafe) var installSpec: RotationSpec?
    nonisolated(unsafe) var wrapKeyExpected: SymmetricKey?
    /// Alternative to `wrapKeyExpected`: accept any wrapKey from this list.
    /// Used by multi-admin iteration tests where only one of N admin-derived
    /// keys should decrypt successfully.
    nonisolated(unsafe) var acceptedWrapKeys: [SymmetricKey]?

    func encode(_ plaintext: RotationPlaintext, recipientPubkey: Data, wrapKey: SymmetricKey) throws -> RotationBlob {
        var bytes = Data([0x03])
        bytes.append(uuidBytes(plaintext.priorKeyID))
        bytes.append(uuidBytes(plaintext.newKeyID))
        bytes.append(recipientPubkey)
        bytes.append(Data(repeating: 0xCC, count: 12))
        bytes.append(Data([0xEE]))
        bytes.append(Data(repeating: 0xDD, count: 16))
        return RotationBlob(bytes: bytes)
    }

    func decode(_ blob: RotationBlob, wrapKey: SymmetricKey) throws -> RotationPlaintext {
        if let expected = wrapKeyExpected,
            expected.withUnsafeBytes({ Data($0) }) != wrapKey.withUnsafeBytes({ Data($0) })
        {
            throw LeafError.rotationBlobMalformed
        }
        if let allowed = acceptedWrapKeys {
            let wkData = wrapKey.withUnsafeBytes { Data($0) }
            let match = allowed.contains { $0.withUnsafeBytes({ Data($0) }) == wkData }
            if !match { throw LeafError.rotationBlobMalformed }
        }
        guard let spec = installSpec else { throw LeafError.rotationBlobMalformed }
        return RotationPlaintext(
            kind: .rotation,
            newTeamKeyBase64: spec.newTeamKeyBase64,
            newKeyID: spec.newKeyID, priorKeyID: spec.priorKeyID,
            generatedAtMs: 1_700_000_000_500,
            removedMemberID: nil
        )
    }

    private func uuidBytes(_ uuidString: String) -> Data {
        guard let uuid = UUID(uuidString: uuidString) else { return Data(repeating: 0, count: 16) }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }
}

// MARK: - Composite codec (routes by peek header)

final class CompositeCodec: RotationBlobCodec, @unchecked Sendable {
    nonisolated(unsafe) var rotation: RotationRecordingCodec?
    nonisolated(unsafe) var tombstone: TombstoneRecordingCodec?

    func encode(_ plaintext: RotationPlaintext, recipientPubkey: Data, wrapKey: SymmetricKey) throws -> RotationBlob {
        switch plaintext.kind {
        case .rotation: return try rotation!.encode(plaintext, recipientPubkey: recipientPubkey, wrapKey: wrapKey)
        case .tombstone: return try tombstone!.encode(plaintext, recipientPubkey: recipientPubkey, wrapKey: wrapKey)
        }
    }

    func decode(_ blob: RotationBlob, wrapKey: SymmetricKey) throws -> RotationPlaintext {
        let header = try RotationBlobHeader.peek(from: blob)
        if header.priorKeyID == header.newKeyID {
            return try tombstone!.decode(blob, wrapKey: wrapKey)
        } else {
            return try rotation!.decode(blob, wrapKey: wrapKey)
        }
    }
}

// MARK: - Mock URLProtocol (file-local)

final class RotationFetchServiceMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> (HTTPURLResponse, Data?))?
    nonisolated(unsafe) static var networkError: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var requestLog: [URLRequest] = []

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
        Self.requestLog.append(request)
        do {
            let (resp, data) = try handler(request, Data())
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func ackCount() -> Int {
        requestLog.filter { $0.httpMethod == "DELETE" }.count
    }
}
