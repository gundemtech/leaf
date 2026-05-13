// Phase 5.1.D — OrgService.createPersonalOrg + currentOrg tests.
// Phase 5.2.A — `randomX25519PrivateKey` injectable заменён на `identity`
// factory; default делегирует в IdentityService.ensureLocalIdentity. +1 test 13.
// Inject'абельные factories (now / randomBytes / randomUUID / identity)
// дают deterministic round-trip — test 12 проверяет конкретные ID / bytes /
// timestamp в DB + keystore files.

import XCTest
import CryptoKit
@testable import LeafCore

final class OrgServiceTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!
    private var db: Database!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-orgservice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Builds OrgService с default-factories (real RNG / Curve25519). Дeterministic
    /// `now` callback всё равно полезен — SQLCipher ms precision rounds Date(),
    /// inject whole-second avoids round-trip drift.
    private func makeService(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> OrgService {
        return OrgService(
            database: db,
            keystoreRoot: keystoreRoot,
            now: { now }
        )
    }

    // MARK: - 1. Three rows + FK chain

    func testCreatePersonalOrg_WritesAllThreeRows() throws {
        let svc = makeService()
        _ = try svc.createPersonalOrg(displayName: "Personal")

        let org = try db.listWorkspaces(includeLeft: true).first
        XCTAssertNotNil(org)

        let members = try db.readTeamMembers(workspaceID: org!.id)
        XCTAssertEqual(members.count, 1)
        let self_ = members[0]

        let teamKey = try db.readActiveTeamKey(workspaceID: org!.id)
        XCTAssertNotNil(teamKey)

        // FK chain: org.createdByMemberID == member.id == teamKey.generatedByMemberID.
        XCTAssertEqual(org!.createdByMemberID, self_.id)
        XCTAssertEqual(teamKey!.generatedByMemberID, self_.id)
        XCTAssertEqual(self_.workspaceID, org!.id)
    }

    // MARK: - 2. Admin role + 64-char hex pubkey

    func testCreatePersonalOrg_WritesAdminMemberWithSelfPubkey64Chars() throws {
        let svc = makeService()
        _ = try svc.createPersonalOrg(displayName: "Personal")

        let org = try db.listWorkspaces(includeLeft: true).first
        let members = try db.readTeamMembers(workspaceID: org!.id)
        let self_ = members[0]

        XCTAssertEqual(self_.role, .admin)
        XCTAssertEqual(self_.pubkeyHex.count, 64)
        // Hex regex.
        let hex = try NSRegularExpression(pattern: "^[0-9a-f]{64}$")
        let range = NSRange(self_.pubkeyHex.startIndex..., in: self_.pubkeyHex)
        XCTAssertNotNil(hex.firstMatch(in: self_.pubkeyHex, range: range))
    }

    // MARK: - 3. Org fields

    func testCreatePersonalOrg_OrgFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let svc = makeService(now: now)
        let returned = try svc.createPersonalOrg(displayName: "Personal")

        XCTAssertEqual(returned.name, "Personal")
        XCTAssertEqual(returned.createdAt, now)

        let stored = try db.listWorkspaces(includeLeft: true).first
        XCTAssertEqual(stored?.id, returned.id)
        XCTAssertEqual(stored?.name, "Personal")
        XCTAssertEqual(stored?.createdAt, now)
        XCTAssertEqual(stored?.createdByMemberID, returned.createdByMemberID)
    }

    // MARK: - 4. TeamKey fields

    func testCreatePersonalOrg_TeamKeyFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let svc = makeService(now: now)
        _ = try svc.createPersonalOrg(displayName: "Personal")

        let org = try db.listWorkspaces(includeLeft: true).first!
        let teamKey = try db.readActiveTeamKey(workspaceID: org.id)!
        let self_ = (try db.readTeamMembers(workspaceID: org.id))[0]

        XCTAssertEqual(teamKey.generatedAt, now)
        XCTAssertNil(teamKey.deprecatedAt)
        XCTAssertEqual(teamKey.generatedByMemberID, self_.id)
    }

    // MARK: - 5. X25519 priv file — 0o600 + 32B

    func testCreatePersonalOrg_WritesX25519PrivateFile_0600_32B() throws {
        let svc = makeService()
        _ = try svc.createPersonalOrg(displayName: "Personal")

        let path = keystoreRoot
            .appendingPathComponent(TeamKeystore.x25519PrivateFilename)
            .path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(data.count, 32)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perm & 0o777, 0o600)
    }

    // MARK: - 6. TeamKey file — 0o600 + 32B + named by id

    func testCreatePersonalOrg_WritesTeamKeyFile_0600_32B_NamedByID() throws {
        let svc = makeService()
        _ = try svc.createPersonalOrg(displayName: "Personal")

        let org = try db.listWorkspaces(includeLeft: true).first!
        let teamKey = try db.readActiveTeamKey(workspaceID: org.id)!
        let path = keystoreRoot
            .appendingPathComponent(TeamKeystore.teamKeysSubdir, isDirectory: true)
            .appendingPathComponent("\(teamKey.id).\(TeamKeystore.teamKeyExtension)")
            .path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "expected file at \(path)")

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(data.count, 32)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perm & 0o777, 0o600)

        // Filename use lowercase UUID — id stored in DB matches filename component.
        XCTAssertEqual(teamKey.id, teamKey.id.lowercased())
    }

    // MARK: - 7. Idempotency guard

    func testCreatePersonalOrg_ThrowsIfAlreadyExists() throws {
        let svc = makeService()
        _ = try svc.createPersonalOrg(displayName: "Personal")

        XCTAssertThrowsError(try svc.createPersonalOrg(displayName: "Other")) { error in
            XCTAssertTrue(isOrgAlreadyExists(error), "got: \(error)")
        }

        // DB row counts unchanged.
        let org = try db.listWorkspaces(includeLeft: true).first!
        XCTAssertEqual(org.name, "Personal")  // not "Other"
        let members = try db.readTeamMembers(workspaceID: org.id)
        XCTAssertEqual(members.count, 1)
    }

    // MARK: - 8. Empty / whitespace displayName

    func testCreatePersonalOrg_EmptyDisplayName_Throws() throws {
        let svc = makeService()

        for input in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try svc.createPersonalOrg(displayName: input),
                                 "input='\(input)' must throw") { error in
                XCTAssertTrue(isInvalidPayload(error), "input='\(input)' got: \(error)")
            }
        }

        // Nothing written.
        XCTAssertNil(try db.listWorkspaces(includeLeft: true).first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keystoreRoot.path))
    }

    // MARK: - 9. Trim displayName

    func testCreatePersonalOrg_TrimsDisplayName() throws {
        let svc = makeService()
        let returned = try svc.createPersonalOrg(displayName: "  Alice  ")

        XCTAssertEqual(returned.name, "Alice")

        let org = try db.listWorkspaces(includeLeft: true).first
        XCTAssertEqual(org?.name, "Alice")
        let members = try db.readTeamMembers(workspaceID: org!.id)
        XCTAssertEqual(members[0].displayName, "Alice")
    }

    // MARK: - 10. currentOrg pass-through

    func testCurrentOrg_ReturnsNilBeforeCreate_AndOrgAfterCreate() throws {
        let svc = makeService()

        XCTAssertNil(try svc.currentOrg())

        let returned = try svc.createPersonalOrg(displayName: "Personal")
        let current = try svc.currentOrg()
        XCTAssertEqual(current?.id, returned.id)
        XCTAssertEqual(current?.name, "Personal")
    }

    // MARK: - 11. X25519 priv → public derivation matches member.pubkeyHex

    func testCreatePersonalOrg_X25519_PrivateMatchesPublicKeyDerivation() throws {
        let svc = makeService()
        _ = try svc.createPersonalOrg(displayName: "Personal")

        let privBytes = try TeamKeystore.readX25519Private(at: keystoreRoot)
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privBytes)
        let derivedPub = priv.publicKey.rawRepresentation
        let derivedHex = derivedPub.map { String(format: "%02x", $0) }.joined()

        let org = try db.listWorkspaces(includeLeft: true).first!
        let self_ = (try db.readTeamMembers(workspaceID: org.id))[0]
        XCTAssertEqual(self_.pubkeyHex, derivedHex)
    }

    // MARK: - 12. Injectable factories — deterministic round-trip

    func testCreatePersonalOrg_IsInjectable() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // UUID counter: 1=selfMemberID, 2=orgID, 3=teamKeyID (per spec step 3 order).
        let uuidCounter = UUIDCounter()

        let teamKeyBytes = Data(repeating: 0xAB, count: 32)
        let fixedPriv = Curve25519.KeyAgreement.PrivateKey()
        let fixedPub = fixedPriv.publicKey.rawRepresentation
        let fixedPubHex = fixedPub.map { String(format: "%02x", $0) }.joined()

        let injectedKeystoreRoot = keystoreRoot!
        let svc = OrgService(
            database: db,
            keystoreRoot: keystoreRoot,
            now: { now },
            randomBytes: { count in
                XCTAssertEqual(count, 32)
                return teamKeyBytes
            },
            randomUUID: { uuidCounter.next() },
            // 5.2.A: identity factory mirror'ит default IdentityService path —
            // generate-then-write — но с deterministic `fixedPriv`. Сохраняет
            // file-write side effect (assertion ниже verify'ит storedPriv).
            identity: {
                try IdentityService.ensureLocalIdentity(at: injectedKeystoreRoot,
                                                        generate: { fixedPriv })
            }
        )

        let returned = try svc.createPersonalOrg(displayName: "Personal")

        // ID assignment per step 3 order.
        XCTAssertEqual(returned.createdByMemberID, "fixed-uuid-1")
        XCTAssertEqual(returned.id, "fixed-uuid-2")

        let teamKey = try db.readActiveTeamKey(workspaceID: returned.id)!
        XCTAssertEqual(teamKey.id, "fixed-uuid-3")
        XCTAssertEqual(teamKey.generatedByMemberID, "fixed-uuid-1")
        XCTAssertEqual(teamKey.generatedAt, now)

        // Member fields.
        let self_ = (try db.readTeamMembers(workspaceID: returned.id))[0]
        XCTAssertEqual(self_.id, "fixed-uuid-1")
        XCTAssertEqual(self_.pubkeyHex, fixedPubHex)
        XCTAssertEqual(self_.addedAt, now)

        // Keystore files reflect injection.
        let storedPriv = try TeamKeystore.readX25519Private(at: keystoreRoot)
        XCTAssertEqual(storedPriv, fixedPriv.rawRepresentation)

        let storedTeamKey = try TeamKeystore.readTeamKey(id: "fixed-uuid-3", at: keystoreRoot)
        XCTAssertEqual(storedTeamKey, teamKeyBytes)
    }

    // MARK: - 13. Default identity factory reads existing keystore file (Phase 5.2.A)

    /// Регрессионный test для refactor 5.2.A: default `identity` factory
    /// делегирует в `IdentityService.ensureLocalIdentity` который reads
    /// existing X25519 priv с диска вместо overwrite. Pre-write 32B priv,
    /// затем createPersonalOrg без inject — assert member.pubkeyHex
    /// derives from pre-written priv.
    func testCreatePersonalOrg_DefaultIdentityFactory_ReadsExistingKeystoreFile() throws {
        let knownPriv = Curve25519.KeyAgreement.PrivateKey()
        try TeamKeystore.writeX25519Private(knownPriv.rawRepresentation, at: keystoreRoot)

        let svc = OrgService(database: db, keystoreRoot: keystoreRoot)
        _ = try svc.createPersonalOrg(displayName: "Alice")

        let org = try db.listWorkspaces(includeLeft: true).first!
        let self_ = (try db.readTeamMembers(workspaceID: org.id))[0]

        let knownPubHex = knownPriv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(self_.pubkeyHex, knownPubHex)

        // Existing X25519 file untouched (bytes equal pre-written sentinel).
        let onDisk = try TeamKeystore.readX25519Private(at: keystoreRoot)
        XCTAssertEqual(onDisk, knownPriv.rawRepresentation)
    }

    // MARK: - Helpers

    private func isOrgAlreadyExists(_ error: Error) -> Bool {
        guard let leafErr = error as? LeafError else { return false }
        if case .orgAlreadyExists = leafErr { return true }
        return false
    }

    private func isInvalidPayload(_ error: Error) -> Bool {
        guard let leafErr = error as? LeafError else { return false }
        if case .invalidPayload = leafErr { return true }
        return false
    }
}

/// Deterministic UUID counter для test 12. Mutable state — wrapped to satisfy
/// `@Sendable () -> String` callback (sendable closure capture-by-reference
/// требует locked storage; NSLock самый дешёвый при single-thread test usage).
private final class UUIDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return "fixed-uuid-\(counter)"
    }
}
