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
