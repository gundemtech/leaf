// Phase 5.1.E — OrgService + Database + TeamKeystore E2E persistence tests.
// Покрывает гэп beyond OrgServiceTests: что happens при close+reopen DB
// (idempotency guard survives, file bytes survive, ID references match).

import XCTest
import CryptoKit
@testable import LeafCore

final class OrgPersistenceIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var keystoreRoot: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-orgpersist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func openDB() throws -> Database {
        return try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    }

    // MARK: - 1. DB rows + keystore files survive close+reopen

    func testCreate_DBAndKeystoreSurviveReopen() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Phase 1: create на свежей DB.
        var db: Database? = try openDB()
        let svc1 = OrgService(database: db!, keystoreRoot: keystoreRoot, now: { now })
        let createdOrg = try svc1.createPersonalOrg(displayName: "Personal")
        let createdMembers = try db!.readTeamMembers(orgID: createdOrg.id)
        XCTAssertEqual(createdMembers.count, 1)
        let createdMember = createdMembers[0]
        let createdTeamKey = try db!.readActiveTeamKey()!

        // Close DB pool (deinit DatabasePool releases SQLite handles).
        db = nil

        // Phase 2: re-open same on-disk DB.
        let db2 = try openDB()

        // DB rows match exactly.
        let reopenedOrg = try db2.readOrg()
        XCTAssertNotNil(reopenedOrg)
        XCTAssertEqual(reopenedOrg?.id, createdOrg.id)
        XCTAssertEqual(reopenedOrg?.name, "Personal")
        XCTAssertEqual(reopenedOrg?.createdAt, now)
        XCTAssertEqual(reopenedOrg?.createdByMemberID, createdMember.id)

        let reopenedMembers = try db2.readTeamMembers(orgID: reopenedOrg!.id)
        XCTAssertEqual(reopenedMembers.count, 1)
        XCTAssertEqual(reopenedMembers[0].id, createdMember.id)
        XCTAssertEqual(reopenedMembers[0].role, .admin)
        XCTAssertEqual(reopenedMembers[0].pubkeyHex, createdMember.pubkeyHex)
        XCTAssertEqual(reopenedMembers[0].displayName, "Personal")

        let reopenedTeamKey = try db2.readActiveTeamKey()
        XCTAssertEqual(reopenedTeamKey?.id, createdTeamKey.id)
        XCTAssertEqual(reopenedTeamKey?.generatedAt, now)
        XCTAssertNil(reopenedTeamKey?.deprecatedAt)
        XCTAssertEqual(reopenedTeamKey?.generatedByMemberID, createdMember.id)

        // Keystore files on disk: existence + sizes (independent от DB lifecycle).
        let privPath = keystoreRoot
            .appendingPathComponent(TeamKeystore.x25519PrivateFilename).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: privPath))
        let privBytes = try Data(contentsOf: URL(fileURLWithPath: privPath))
        XCTAssertEqual(privBytes.count, TeamKeystore.x25519PrivateLength)

        let teamKeyPath = keystoreRoot
            .appendingPathComponent(TeamKeystore.teamKeysSubdir, isDirectory: true)
            .appendingPathComponent("\(createdTeamKey.id).\(TeamKeystore.teamKeyExtension)").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: teamKeyPath))
        let teamKeyBytes = try Data(contentsOf: URL(fileURLWithPath: teamKeyPath))
        XCTAssertEqual(teamKeyBytes.count, TeamKeystore.teamKeyLength)
    }

    // MARK: - 2. Idempotency guard survives reopen

    func testCreate_SecondAttempt_AfterReopen_ThrowsOrgAlreadyExists() throws {
        // Phase 1: первый create.
        var db: Database? = try openDB()
        let svc1 = OrgService(database: db!, keystoreRoot: keystoreRoot)
        _ = try svc1.createPersonalOrg(displayName: "Personal")
        db = nil

        // Phase 2: re-open + second OrgService instance + retry create.
        let db2 = try openDB()
        let svc2 = OrgService(database: db2, keystoreRoot: keystoreRoot)

        XCTAssertThrowsError(try svc2.createPersonalOrg(displayName: "Other")) { error in
            guard let leafErr = error as? LeafError,
                  case .orgAlreadyExists = leafErr else {
                XCTFail("expected .orgAlreadyExists, got: \(error)")
                return
            }
        }

        // DB state unchanged after rejected second attempt.
        let org = try db2.readOrg()
        XCTAssertEqual(org?.name, "Personal")
        let members = try db2.readTeamMembers(orgID: org!.id)
        XCTAssertEqual(members.count, 1)
    }

    // MARK: - 3. Keystore teamKey file bytes match injected sentinel

    func testCreate_KeystoreTeamKeyFileBytesMatchInjected() throws {
        let sentinel = Data(repeating: 0xCD, count: TeamKeystore.teamKeyLength)

        let db = try openDB()
        let svc = OrgService(
            database: db,
            keystoreRoot: keystoreRoot,
            randomBytes: { count in
                XCTAssertEqual(count, TeamKeystore.teamKeyLength)
                return sentinel
            }
        )
        _ = try svc.createPersonalOrg(displayName: "Personal")

        let teamKey = try db.readActiveTeamKey()!
        let onDiskPath = keystoreRoot
            .appendingPathComponent(TeamKeystore.teamKeysSubdir, isDirectory: true)
            .appendingPathComponent("\(teamKey.id).\(TeamKeystore.teamKeyExtension)").path

        let onDiskBytes = try Data(contentsOf: URL(fileURLWithPath: onDiskPath))
        XCTAssertEqual(onDiskBytes, sentinel)

        // Закрывает gap "DB row id-references file, файл реально содержит то что
        // было сгенерировано" — сanity что `randomBytes` factory не лиспит данные
        // между точкой генерации и точкой записи.
    }
}
