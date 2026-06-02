// Phase 5.1.B — public-side tests for team helpers (Org / TeamMember / TeamKey)
// on top of the M006/M007/M008 schema substrate from 5.1.A. Pure DB I/O round-trip + edge
// cases (partial-index queries via direct `removed_at_ms` / `deprecated_at_ms`
// SET through the `db.writeSQL` raw-SQL escape — mark/deprecate helpers — task 5.3).

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

    /// Basic round-trip: upsert → readOrg returns the same row, all 4 fields
    /// match, Date round-trips without loss (whole-second timestamps).
    func testUpsertOrgAndReadRoundTrip() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let org = Workspace(
            id: "org-aaaa",
            name: "Personal",
            createdAt: createdAt,
            createdByMemberID: "member-self"
        )
        try db.upsertWorkspace(org)

        let loaded = try db.listWorkspaces(includeLeft: true).first
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "org-aaaa")
        XCTAssertEqual(loaded?.name, "Personal")
        XCTAssertEqual(loaded?.createdAt, createdAt)
        XCTAssertEqual(loaded?.createdByMemberID, "member-self")
    }

    /// UPSERT by PK — re-write with the same `id` but a new `name` updates the fields.
    func testUpsertOrgUpdatesFieldsForSameID() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let initial = Workspace(
            id: "org-aaaa",
            name: "Personal",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "member-self"
        )
        try db.upsertWorkspace(initial)

        let renamed = Workspace(
            id: "org-aaaa",
            name: "Acme Inc",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "member-self"
        )
        try db.upsertWorkspace(renamed)

        let loaded = try db.listWorkspaces(includeLeft: true).first
        XCTAssertEqual(loaded?.name, "Acme Inc", "UPSERT should have updated name")
    }

    /// Fresh DB without an upsert → readOrg() == nil.
    func testReadOrgReturnsNilWhenEmpty() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        let loaded = try db.listWorkspaces(includeLeft: true).first
        XCTAssertNil(loaded)
    }

    // MARK: - TeamMembers

    /// Insert 2 active members → readTeamMembers(includeRemoved:true) returns both,
    /// ordered by addedAt.
    func testInsertTeamMemberAndReadAll() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let earlier = TeamMember(
            id: "member-self",
            workspaceID: "org-aaaa",
            role: .admin,
            pubkeyHex: String(repeating: "ab", count: 32),
            displayName: "Alex",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            removedAt: nil
        )
        let later = TeamMember(
            id: "member-2",
            workspaceID: "org-aaaa",
            role: .member,
            pubkeyHex: String(repeating: "cd", count: 32),
            displayName: "Sasha",
            addedAt: Date(timeIntervalSince1970: 1_700_001_000),
            removedAt: nil
        )
        try db.insertTeamMember(earlier)
        try db.insertTeamMember(later)

        let members = try db.readTeamMembers(workspaceID: "org-aaaa", includeRemoved: true)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0].id, "member-self", "must be ordered by addedAt ASC")
        XCTAssertEqual(members[0].role, .admin)
        XCTAssertEqual(members[0].pubkeyHex, String(repeating: "ab", count: 32))
        XCTAssertEqual(members[0].displayName, "Alex")
        XCTAssertNil(members[0].removedAt)
        XCTAssertEqual(members[1].id, "member-2")
        XCTAssertEqual(members[1].role, .member)
    }

    /// Default `includeRemoved: false` → excludes members with `removed_at_ms` set.
    /// Mark-removed setup via the writeSQL escape (5.3 helper, not 5.1.B).
    func testReadTeamMembersExcludesRemovedByDefault() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try insertSampleMembers(db, orgID: "org-aaaa")

        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "UPDATE \(Schema.TeamMembers.tableName) SET \(Schema.TeamMembers.removedAtMs) = ? WHERE \(Schema.TeamMembers.id) = ?",
                arguments: [Int64(1_700_002_000_000), "member-2"]
            )
        }

        let activeOnly = try db.readTeamMembers(workspaceID: "org-aaaa")
        XCTAssertEqual(activeOnly.count, 1)
        XCTAssertEqual(activeOnly[0].id, "member-self")
        XCTAssertNil(activeOnly[0].removedAt)
    }

    /// `includeRemoved: true` returns all rows — active + removed.
    /// Confirms that removed_at_ms serializes correctly (Date round-trip).
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

        let all = try db.readTeamMembers(workspaceID: "org-aaaa", includeRemoved: true)
        XCTAssertEqual(all.count, 2)
        let removed = all.first { $0.id == "member-2" }
        XCTAssertEqual(removed?.removedAt, Date(timeIntervalSince1970: TimeInterval(removedAtMs) / 1000.0))
    }

    /// Sanity: insert members into two different org_id → readTeamMembers filters
    /// by orgID. Single-org-per-device is not constrained at the DB level; we guard against it.
    func testReadTeamMembersFiltersByOrgID() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try insertSampleMembers(db, orgID: "org-aaaa")
        let foreign = TeamMember(
            id: "member-foreign",
            workspaceID: "org-bbbb",
            role: .member,
            pubkeyHex: String(repeating: "ef", count: 32),
            displayName: "Foreign",
            addedAt: Date(timeIntervalSince1970: 1_700_003_000),
            removedAt: nil
        )
        try db.insertTeamMember(foreign)

        let aMembers = try db.readTeamMembers(workspaceID: "org-aaaa", includeRemoved: true)
        XCTAssertEqual(aMembers.count, 2)
        XCTAssertFalse(aMembers.contains { $0.id == "member-foreign" })

        let bMembers = try db.readTeamMembers(workspaceID: "org-bbbb")
        XCTAssertEqual(bMembers.count, 1)
        XCTAssertEqual(bMembers[0].id, "member-foreign")
    }

    // MARK: - TeamKeys

    /// Insert 1 active key (`deprecatedAt: nil`) → readActiveTeamKey returns it,
    /// all 4 fields match, Date round-trips without loss.
    func testInsertTeamKeyAndReadActive() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let key = TeamKey(
            id: "key-rotation-1",
            workspaceID: "org-aaaa",
            generatedAt: generatedAt,
            deprecatedAt: nil,
            generatedByMemberID: "member-self"
        )
        try db.insertTeamKey(key)

        let active = try db.readActiveTeamKey(workspaceID: "org-aaaa")
        XCTAssertNotNil(active)
        XCTAssertEqual(active?.id, "key-rotation-1")
        XCTAssertEqual(active?.generatedAt, generatedAt)
        XCTAssertNil(active?.deprecatedAt)
        XCTAssertEqual(active?.generatedByMemberID, "member-self")
    }

    /// Mark key as deprecated via the writeSQL escape (deprecate helper — task 5.3) →
    /// readActiveTeamKey() == nil (partial index `team_keys_active` filters it out).
    func testReadActiveTeamKeyExcludesDeprecated() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        try db.insertTeamKey(TeamKey(
            id: "key-rotation-1",
            workspaceID: "org-aaaa",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deprecatedAt: nil,
            generatedByMemberID: "member-self"
        ))

        try db.writeSQL { rawDB in
            try rawDB.execute(
                sql: "UPDATE \(Schema.TeamKeys.tableName) SET \(Schema.TeamKeys.deprecatedAtMs) = ? WHERE \(Schema.TeamKeys.id) = ?",
                arguments: [Int64(1_700_001_000_000), "key-rotation-1"]
            )
        }

        let active = try db.readActiveTeamKey(workspaceID: "org-aaaa")
        XCTAssertNil(active)
    }

    /// Defensive: with two active rows (normally 1, but not constrained by
    /// contract at the DB level) — returns the one with the latest `generated_at_ms`.
    func testReadActiveTeamKeyReturnsLatestByGeneratedAt() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        let earlier = TeamKey(
            id: "key-rotation-1",
            workspaceID: "org-aaaa",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deprecatedAt: nil,
            generatedByMemberID: "member-self"
        )
        let later = TeamKey(
            id: "key-rotation-2",
            workspaceID: "org-aaaa",
            generatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            deprecatedAt: nil,
            generatedByMemberID: "member-self"
        )
        try db.insertTeamKey(earlier)
        try db.insertTeamKey(later)

        let active = try db.readActiveTeamKey(workspaceID: "org-aaaa")
        XCTAssertEqual(active?.id, "key-rotation-2", "ORDER BY generated_at_ms DESC LIMIT 1 — the latest must be returned")
    }

    // MARK: - Mode guard

    /// Reader-mode `Database` — all 3 write helpers throw `databaseUnavailable`.
    /// Covers upsertOrg / insertTeamMember / insertTeamKey in a single battery.
    func testReaderModeWriteHelpersThrowDatabaseUnavailable() throws {
        // First the writer creates the schema + one row for the contention test:
        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try writer.upsertWorkspace(Workspace(
            id: "org-aaaa",
            name: "Personal",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdByMemberID: "member-self"
        ))

        let reader = try Database.openForRead(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertThrowsError(try reader.upsertWorkspace(Workspace(
            id: "org-bbbb", name: "Other",
            createdAt: Date(timeIntervalSince1970: 1_700_001_000),
            createdByMemberID: "member-self"
        ))) { error in
            XCTAssertEqual(error as? LeafError, .databaseUnavailable)
        }

        XCTAssertThrowsError(try reader.insertTeamMember(TeamMember(
            id: "member-x", workspaceID: "org-aaaa", role: .member,
            pubkeyHex: String(repeating: "ab", count: 32),
            displayName: "X",
            addedAt: Date(timeIntervalSince1970: 1_700_001_000),
            removedAt: nil
        ))) { error in
            XCTAssertEqual(error as? LeafError, .databaseUnavailable)
        }

        XCTAssertThrowsError(try reader.insertTeamKey(TeamKey(
            id: "key-x",
            workspaceID: "org-aaaa",
            generatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            deprecatedAt: nil,
            generatedByMemberID: "member-self"
        ))) { error in
            XCTAssertEqual(error as? LeafError, .databaseUnavailable)
        }
    }

    // MARK: - Helpers

    private func insertSampleMembers(_ db: LeafCore.Database, orgID: String) throws {
        try db.insertTeamMember(TeamMember(
            id: "member-self",
            workspaceID: orgID,
            role: .admin,
            pubkeyHex: String(repeating: "ab", count: 32),
            displayName: "Alex",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            removedAt: nil
        ))
        try db.insertTeamMember(TeamMember(
            id: "member-2",
            workspaceID: orgID,
            role: .member,
            pubkeyHex: String(repeating: "cd", count: 32),
            displayName: "Sasha",
            addedAt: Date(timeIntervalSince1970: 1_700_001_000),
            removedAt: nil
        ))
    }
}
