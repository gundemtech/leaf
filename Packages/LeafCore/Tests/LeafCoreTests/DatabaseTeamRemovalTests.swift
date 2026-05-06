// Phase 5.3.A — public-side tests для team lifecycle mutators
// (markTeamMemberRemoved / deprecateTeamKey / readTeamKey(byID:)) поверх
// 5.1.B helpers. Pure DB I/O round-trip + idempotency + invariant guards.

import XCTest
import GRDB
@testable import LeafCore

final class DatabaseTeamRemovalTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leaf-team-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - markTeamMemberRemoved

    /// Active member → mark → row's `removed_at_ms` set; partial index
    /// `team_members_org_active` исключает (через default `readTeamMembers` call).
    func testMarkTeamMemberRemoved_HappyPath() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleMembers(db, orgID: "org-aaaa")

        let removedAt = Date(timeIntervalSince1970: 1_700_002_000)
        try db.markTeamMemberRemoved(memberID: "member-2", at: removedAt)

        let active = try db.readTeamMembers(orgID: "org-aaaa")
        XCTAssertEqual(active.count, 1, "removed member должен быть исключён партиал-индексом")
        XCTAssertEqual(active[0].id, "member-self")

        let all = try db.readTeamMembers(orgID: "org-aaaa", includeRemoved: true)
        let removed = all.first { $0.id == "member-2" }
        XCTAssertEqual(removed?.removedAt, removedAt)
    }

    /// Mark twice with different timestamps → row's `removed_at_ms`
    /// preserves first call's value (idempotent no-op on second call).
    func testMarkTeamMemberRemoved_IsIdempotent() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleMembers(db, orgID: "org-aaaa")

        let firstRemovedAt = Date(timeIntervalSince1970: 1_700_002_000)
        let secondRemovedAt = Date(timeIntervalSince1970: 1_700_003_000)

        try db.markTeamMemberRemoved(memberID: "member-2", at: firstRemovedAt)
        try db.markTeamMemberRemoved(memberID: "member-2", at: secondRemovedAt)

        let all = try db.readTeamMembers(orgID: "org-aaaa", includeRemoved: true)
        let removed = all.first { $0.id == "member-2" }
        XCTAssertEqual(removed?.removedAt, firstRemovedAt,
            "повторный mark не должен bump'ить timestamp")
    }

    /// Mark с non-existent UUID → throws `.invalidPayload`; existing rows untouched.
    func testMarkTeamMemberRemoved_MissingMemberThrowsInvalidPayload() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleMembers(db, orgID: "org-aaaa")

        XCTAssertThrowsError(
            try db.markTeamMemberRemoved(memberID: "member-nonexistent", at: Date(timeIntervalSince1970: 1_700_002_000))
        ) { error in
            XCTAssertEqual(error as? LeafError, .invalidPayload)
        }

        // Sanity — existing rows не trogany.
        let all = try db.readTeamMembers(orgID: "org-aaaa", includeRemoved: true)
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.removedAt == nil })
    }

    /// Reader-mode DB → throws `.databaseUnavailable` (mode guard).
    func testMarkTeamMemberRemoved_ReaderModeThrowsDatabaseUnavailable() throws {
        // Setup через writer.
        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleMembers(writer, orgID: "org-aaaa")

        let reader = try Database.openForRead(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertThrowsError(
            try reader.markTeamMemberRemoved(memberID: "member-2", at: Date(timeIntervalSince1970: 1_700_002_000))
        ) { error in
            XCTAssertEqual(error as? LeafError, .databaseUnavailable)
        }
    }

    // MARK: - deprecateTeamKey

    /// 2 active keys → deprecate one → row's `deprecated_at_ms` set;
    /// other key remains active (`readActiveTeamKey()` returns the other).
    func testDeprecateTeamKey_HappyPathWithMultipleActive() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleKeys(db)

        let deprecatedAt = Date(timeIntervalSince1970: 1_700_002_000)
        try db.deprecateTeamKey(keyID: "key-rotation-1", at: deprecatedAt)

        // After deprecate — key-rotation-2 остаётся active.
        let active = try db.readActiveTeamKey()
        XCTAssertEqual(active?.id, "key-rotation-2")
        XCTAssertNil(active?.deprecatedAt)
    }

    /// 1 active key → deprecate it → throws `.invalidPayload`;
    /// row remains active (sole-active guard kept intact).
    func testDeprecateTeamKey_SoleActiveGuardThrows() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try db.insertTeamKey(TeamKey(
            id: "key-rotation-1",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deprecatedAt: nil,
            generatedByMemberID: "member-self"
        ))

        XCTAssertThrowsError(
            try db.deprecateTeamKey(keyID: "key-rotation-1", at: Date(timeIntervalSince1970: 1_700_002_000))
        ) { error in
            XCTAssertEqual(error as? LeafError, .invalidPayload)
        }

        // Sanity — row остаётся active.
        let active = try db.readActiveTeamKey()
        XCTAssertEqual(active?.id, "key-rotation-1")
        XCTAssertNil(active?.deprecatedAt)
    }

    /// Deprecate already-deprecated row → preserves first `deprecated_at_ms`,
    /// не trip'ает sole-active guard даже когда осталась только 1 active row
    /// в системе (deprecating already-deprecated = no-op без actual mutation).
    func testDeprecateTeamKey_IsIdempotentOnAlreadyDeprecated() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleKeys(db)

        // Сначала deprecate'ит key-rotation-1 (active count: 2 → 1).
        let firstDeprecatedAt = Date(timeIntervalSince1970: 1_700_002_000)
        try db.deprecateTeamKey(keyID: "key-rotation-1", at: firstDeprecatedAt)

        // Re-deprecate того же key — no-op. Active count = 1 (key-rotation-2),
        // НЕ должно trip'нуть sole-active guard, потому что target уже deprecated.
        let secondDeprecatedAt = Date(timeIntervalSince1970: 1_700_003_000)
        try db.deprecateTeamKey(keyID: "key-rotation-1", at: secondDeprecatedAt)

        let stored: Int64? = try db.writeSQL { rawDB in
            try Int64.fetchOne(rawDB, sql: """
                SELECT \(Schema.TeamKeys.deprecatedAtMs)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.id) = ?
                """,
                arguments: ["key-rotation-1"]
            )
        }
        XCTAssertEqual(stored, Int64(firstDeprecatedAt.timeIntervalSince1970 * 1000),
            "повторный deprecate не должен bump'ить timestamp")

        // Sanity — key-rotation-2 всё ещё active.
        let active = try db.readActiveTeamKey()
        XCTAssertEqual(active?.id, "key-rotation-2")
    }

    /// Deprecate с non-existent UUID → throws `.invalidPayload`.
    func testDeprecateTeamKey_MissingKeyThrowsInvalidPayload() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleKeys(db)  // 2 active keys, чтобы не trip'нуть sole-active guard

        XCTAssertThrowsError(
            try db.deprecateTeamKey(keyID: "key-nonexistent", at: Date(timeIntervalSince1970: 1_700_002_000))
        ) { error in
            XCTAssertEqual(error as? LeafError, .invalidPayload)
        }

        // Sanity — both sample keys остаются active.
        let activeCount = try db.writeSQL { rawDB in
            try Int.fetchOne(rawDB, sql: """
                SELECT count(*)
                FROM \(Schema.TeamKeys.tableName)
                WHERE \(Schema.TeamKeys.deprecatedAtMs) IS NULL
                """) ?? -1
        }
        XCTAssertEqual(activeCount, 2)
    }

    /// Reader-mode DB → throws `.databaseUnavailable` (mode guard).
    func testDeprecateTeamKey_ReaderModeThrowsDatabaseUnavailable() throws {
        let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleKeys(writer)

        let reader = try Database.openForRead(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

        XCTAssertThrowsError(
            try reader.deprecateTeamKey(keyID: "key-rotation-1", at: Date(timeIntervalSince1970: 1_700_002_000))
        ) { error in
            XCTAssertEqual(error as? LeafError, .databaseUnavailable)
        }
    }

    /// 2 active keys (older + newer) → deprecate newer → `readActiveTeamKey()`
    /// returns older (verifies partial index `team_keys_active` consistency
    /// after mutation through the new helper).
    func testDeprecateTeamKey_AfterDeprecateLatestActiveReadActiveReturnsOlder() throws {
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
        try insertSampleKeys(db)  // key-rotation-1 (older) + key-rotation-2 (newer), оба active

        try db.deprecateTeamKey(keyID: "key-rotation-2", at: Date(timeIntervalSince1970: 1_700_002_000))

        let active = try db.readActiveTeamKey()
        XCTAssertEqual(active?.id, "key-rotation-1",
            "после deprecate latest active — readActive возвращает older active")
    }

    // MARK: - Helpers

    private func insertSampleKeys(_ db: LeafCore.Database) throws {
        try db.insertTeamKey(TeamKey(
            id: "key-rotation-1",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deprecatedAt: nil,
            generatedByMemberID: "member-self"
        ))
        try db.insertTeamKey(TeamKey(
            id: "key-rotation-2",
            generatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            deprecatedAt: nil,
            generatedByMemberID: "member-self"
        ))
    }

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
