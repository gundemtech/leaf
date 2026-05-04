// Phase 5.1.B — public-side tests для team helpers (Org / TeamMember / TeamKey)
// поверх M006/M007/M008 schema substrate'а 5.1.A. Pure DB I/O round-trip + edge
// cases (partial-index queries via direct `removed_at_ms` / `deprecated_at_ms`
// SET через `db.writeSQL` raw-SQL escape — mark/deprecate helpers — задача 5.3).

import XCTest
import GRDB
@testable import LeafCore

final class DatabaseTeamTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-team-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Org

    /// Базовый round-trip: upsert → readOrg возвращает тот же row, все 4 поля
    /// match'ат, Date roundtrip без потерь (whole-second timestamps).
    func testUpsertOrgAndReadRoundTrip() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let org = Org(
            id: "org-aaaa",
            name: "Personal",
            createdAt: createdAt,
            createdByMemberID: "member-self"
        )
        try db.upsertOrg(org)

        let loaded = try db.readOrg()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "org-aaaa")
        XCTAssertEqual(loaded?.name, "Personal")
        XCTAssertEqual(loaded?.createdAt, createdAt)
        XCTAssertEqual(loaded?.createdByMemberID, "member-self")
    }

    /// UPSERT по PK — re-write с тем же `id`, но новым `name`, обновляет fields.
    func testUpsertOrgUpdatesFieldsForSameID() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let initial = Org(
            id: "org-aaaa",
            name: "Personal",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "member-self"
        )
        try db.upsertOrg(initial)

        let renamed = Org(
            id: "org-aaaa",
            name: "Acme Inc",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "member-self"
        )
        try db.upsertOrg(renamed)

        let loaded = try db.readOrg()
        XCTAssertEqual(loaded?.name, "Acme Inc", "UPSERT должен был обновить name")
    }

    /// Fresh DB без upsert'а → readOrg() == nil.
    func testReadOrgReturnsNilWhenEmpty() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let loaded = try db.readOrg()
        XCTAssertNil(loaded)
    }

    // MARK: - TeamMembers

    /// Insert 2 active members → readTeamMembers(includeRemoved:true) возвращает оба,
    /// ordered by addedAt.
    func testInsertTeamMemberAndReadAll() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let earlier = TeamMember(
            id: "member-self",
            orgID: "org-aaaa",
            role: .admin,
            pubkeyHex: String(repeating: "ab", count: 32),
            displayName: "Dmitrii",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            removedAt: nil
        )
        let later = TeamMember(
            id: "member-2",
            orgID: "org-aaaa",
            role: .member,
            pubkeyHex: String(repeating: "cd", count: 32),
            displayName: "Anton",
            addedAt: Date(timeIntervalSince1970: 1_700_001_000),
            removedAt: nil
        )
        try db.insertTeamMember(earlier)
        try db.insertTeamMember(later)

        let members = try db.readTeamMembers(orgID: "org-aaaa", includeRemoved: true)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0].id, "member-self", "должен быть ordered by addedAt ASC")
        XCTAssertEqual(members[0].role, .admin)
        XCTAssertEqual(members[0].pubkeyHex, String(repeating: "ab", count: 32))
        XCTAssertEqual(members[0].displayName, "Dmitrii")
        XCTAssertNil(members[0].removedAt)
        XCTAssertEqual(members[1].id, "member-2")
        XCTAssertEqual(members[1].role, .member)
    }

    /// Default `includeRemoved: false` → исключает members с set'нутым `removed_at_ms`.
    /// Mark removed setup через writeSQL escape (помощник 5.3, не 5.1.B).
    func testReadTeamMembersExcludesRemovedByDefault() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try insertSampleMembers(db, orgID: "org-aaaa")

        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "UPDATE \(Schema.TeamMembers.tableName) SET \(Schema.TeamMembers.removedAtMs) = ? WHERE \(Schema.TeamMembers.id) = ?",
                arguments: [Int64(1_700_002_000_000), "member-2"]
            )
        }

        let activeOnly = try db.readTeamMembers(orgID: "org-aaaa")
        XCTAssertEqual(activeOnly.count, 1)
        XCTAssertEqual(activeOnly[0].id, "member-self")
        XCTAssertNil(activeOnly[0].removedAt)
    }

    /// `includeRemoved: true` возвращает all rows — active + removed.
    /// Подтверждает что removed_at_ms корректно сериализуется (Date round-trip).
    func testReadTeamMembersIncludeRemovedReturnsAll() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try insertSampleMembers(db, orgID: "org-aaaa")

        let removedAtMs: Int64 = 1_700_002_000_000
        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "UPDATE \(Schema.TeamMembers.tableName) SET \(Schema.TeamMembers.removedAtMs) = ? WHERE \(Schema.TeamMembers.id) = ?",
                arguments: [removedAtMs, "member-2"]
            )
        }

        let all = try db.readTeamMembers(orgID: "org-aaaa", includeRemoved: true)
        XCTAssertEqual(all.count, 2)
        let removed = all.first { $0.id == "member-2" }
        XCTAssertEqual(removed?.removedAt, Date(timeIntervalSince1970: TimeInterval(removedAtMs) / 1000.0))
    }

    /// Sanity: insert members в две разные org_id → readTeamMembers фильтрует
    /// по orgID. Single-org-per-device на DB-уровне не constraint'ится; защищаемся.
    func testReadTeamMembersFiltersByOrgID() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try insertSampleMembers(db, orgID: "org-aaaa")
        let foreign = TeamMember(
            id: "member-foreign",
            orgID: "org-bbbb",
            role: .member,
            pubkeyHex: String(repeating: "ef", count: 32),
            displayName: "Foreign",
            addedAt: Date(timeIntervalSince1970: 1_700_003_000),
            removedAt: nil
        )
        try db.insertTeamMember(foreign)

        let aMembers = try db.readTeamMembers(orgID: "org-aaaa", includeRemoved: true)
        XCTAssertEqual(aMembers.count, 2)
        XCTAssertFalse(aMembers.contains { $0.id == "member-foreign" })

        let bMembers = try db.readTeamMembers(orgID: "org-bbbb")
        XCTAssertEqual(bMembers.count, 1)
        XCTAssertEqual(bMembers[0].id, "member-foreign")
    }

    // MARK: - Helpers

    private func insertSampleMembers(_ db: LeafCore.Database, orgID: String) throws {
        try db.insertTeamMember(TeamMember(
            id: "member-self",
            orgID: orgID,
            role: .admin,
            pubkeyHex: String(repeating: "ab", count: 32),
            displayName: "Dmitrii",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            removedAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: "member-2",
            orgID: orgID,
            role: .member,
            pubkeyHex: String(repeating: "cd", count: 32),
            displayName: "Anton",
            addedAt: Date(timeIntervalSince1970: 1_700_001_000),
            removedAt: nil
        ))
    }
}
