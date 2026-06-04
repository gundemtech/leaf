// Invite team-materialization fix — tests for the atomic, idempotent,
// self-healing materialisation helpers used by both accept paths
// (`JoinRequestService.acceptApproved` + `InviteAcceptService.acceptInvite`).
//
//   - `materializeJoinedWorkspace(workspace:adminMember:selfMember:teamKey:)`
//     — one transaction; upsert workspace (clears left_at + deleted_at),
//       insert-if-absent admin + self (by pubkey), insert-if-absent teamKey.
//   - `insertTeamMemberIfAbsent(_:)` — standalone by-pubkey idempotent insert
//     (admin-side roster, `approve()`).
//
// Idempotency is by pubkey (no UNIQUE constraint on team_members.pubkey_hex);
// done via in-tx SELECT-then-INSERT, race-free under GRDB's serialized writer.

import XCTest
import GRDB
@testable import LeafCore

final class DatabaseMaterializeJoinedWorkspaceTests: XCTestCase {
  private var tempDir: URL!
  private var dbURL: URL!

  private let workspaceID = "ws-mat-001"
  private let adminPubkey = String(repeating: "ab", count: 32)
  private let selfPubkey = String(repeating: "cd", count: 32)
  private let adminMemberID = "admin-mem-1"
  private let selfMemberID = "self-mem-1"
  private let teamKeyID = "key-1"

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-mat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    dbURL = tempDir.appendingPathComponent("events.sqlite")
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - Builders

  private func makeWorkspace(leftAt: Date? = nil, deletedAt: Date? = nil) -> Workspace {
    Workspace(
      id: workspaceID,
      name: "TestRoom",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      createdByMemberID: adminMemberID,
      leftAt: leftAt,
      deletedAt: deletedAt
    )
  }

  private func makeAdmin() -> TeamMember {
    TeamMember(
      id: adminMemberID, workspaceID: workspaceID, role: .admin,
      pubkeyHex: adminPubkey, displayName: "Alice",
      addedAt: Date(timeIntervalSince1970: 1_700_000_000), removedAt: nil
    )
  }

  private func makeSelf(id: String? = nil) -> TeamMember {
    TeamMember(
      id: id ?? selfMemberID, workspaceID: workspaceID, role: .member,
      pubkeyHex: selfPubkey, displayName: "Eve",
      addedAt: Date(timeIntervalSince1970: 1_700_001_000), removedAt: nil
    )
  }

  private func makeKey() -> TeamKey {
    TeamKey(
      id: teamKeyID, workspaceID: workspaceID,
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      deprecatedAt: nil, generatedByMemberID: adminMemberID
    )
  }

  // MARK: - materializeJoinedWorkspace — fresh

  func testMaterialize_Fresh_CreatesWorkspaceMembersKey() throws {
    let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

    try db.materializeJoinedWorkspace(
      workspace: makeWorkspace(), adminMember: makeAdmin(),
      selfMember: makeSelf(), teamKey: makeKey())

    let ws = try db.readWorkspace(id: workspaceID)
    XCTAssertNotNil(ws)
    XCTAssertNil(ws?.leftAt)
    XCTAssertNil(ws?.deletedAt)

    let members = try db.readTeamMembers(workspaceID: workspaceID)
    XCTAssertEqual(members.count, 2, "fresh → admin + self")
    XCTAssertEqual(members.first(where: { $0.role == .admin })?.pubkeyHex, adminPubkey)
    XCTAssertEqual(members.first(where: { $0.role == .member })?.pubkeyHex, selfPubkey)

    XCTAssertEqual(try db.readActiveTeamKey(workspaceID: workspaceID)?.id, teamKeyID)
  }

  // MARK: - Idempotency

  func testMaterialize_RunTwice_NoDuplicates() throws {
    let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

    try db.materializeJoinedWorkspace(
      workspace: makeWorkspace(), adminMember: makeAdmin(),
      selfMember: makeSelf(), teamKey: makeKey())
    // Second run with a DIFFERENT self id but the SAME pubkey — must dedup.
    try db.materializeJoinedWorkspace(
      workspace: makeWorkspace(), adminMember: makeAdmin(),
      selfMember: makeSelf(id: "self-mem-2"), teamKey: makeKey())

    let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: true)
    XCTAssertEqual(members.count, 2, "idempotent — no duplicate admin/self by pubkey")
    XCTAssertEqual(try db.listWorkspaces(includeLeft: true).count, 1)
  }

  // MARK: - insertTeamMemberIfAbsent

  func testInsertTeamMemberIfAbsent_SkipsActiveByPubkey() throws {
    let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    try db.insertTeamMember(makeSelf())
    // Same pubkey, different id → must be skipped.
    try db.insertTeamMemberIfAbsent(makeSelf(id: "other-id"))

    let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: true)
    XCTAssertEqual(members.count, 1)
    XCTAssertEqual(members[0].id, selfMemberID)
  }

  func testInsertTeamMemberIfAbsent_ReactivatesRemovedByInsertingFreshActiveRow() throws {
    let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    try db.insertTeamMember(makeSelf())
    try db.writeSQL { raw in
      try raw.execute(
        sql: "UPDATE \(Schema.TeamMembers.tableName) SET \(Schema.TeamMembers.removedAtMs) = ? WHERE \(Schema.TeamMembers.id) = ?",
        arguments: [Int64(1_700_002_000_000), selfMemberID])
    }
    // The only row for this pubkey is REMOVED → insert-if-absent must add a fresh active row.
    try db.insertTeamMemberIfAbsent(makeSelf(id: "self-reactivated"))

    XCTAssertEqual(try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: false).count, 1,
      "exactly one ACTIVE row (the reactivated one)")
    XCTAssertEqual(try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: true).count, 2,
      "old removed row preserved for audit")
    XCTAssertEqual(try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: false).first?.id,
      "self-reactivated")
  }

  // MARK: - Atomicity (rollback)

  func testMaterialize_ForcedMidWriteFailure_RollsBackEntirely() throws {
    let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    // Pre-seed: workspace marked LEFT + a stray member whose id collides with
    // selfMember.id but a DIFFERENT pubkey, so the self insert-if-absent's
    // INSERT hits a PK collision *after* the workspace upsert + admin insert ran.
    try db.upsertWorkspace(makeWorkspace(leftAt: Date(timeIntervalSince1970: 1_715_000_000)))
    try db.insertTeamMember(TeamMember(
      id: selfMemberID, workspaceID: workspaceID, role: .member,
      pubkeyHex: String(repeating: "ff", count: 32), displayName: "Stray",
      addedAt: Date(timeIntervalSince1970: 1_700_000_500), removedAt: nil))

    XCTAssertThrowsError(try db.materializeJoinedWorkspace(
      workspace: makeWorkspace(), adminMember: makeAdmin(),
      selfMember: makeSelf(), teamKey: makeKey()))

    // Full rollback: left_at NOT cleared, admin NOT inserted, only the stray remains.
    XCTAssertNotNil(try db.readWorkspace(id: workspaceID)?.leftAt, "workspace upsert must roll back")
    let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: true)
    XCTAssertEqual(members.count, 1, "admin insert must roll back")
    XCTAssertFalse(members.contains { $0.pubkeyHex == adminPubkey }, "no admin row committed")
    XCTAssertNil(try db.readActiveTeamKey(workspaceID: workspaceID), "no key committed")
  }

  // MARK: - Self-heal: left + deleted

  func testMaterialize_OverLeftAndDeletedWorkspace_ResurrectsAndPopulates() throws {
    let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    // Orphan/abandoned: workspace soft-left AND soft-deleted, no members, no key.
    // `upsertWorkspace` doesn't thread deleted_at_ms — set it via the raw escape.
    try db.upsertWorkspace(makeWorkspace(leftAt: Date(timeIntervalSince1970: 1_715_000_000)))
    try db.writeSQL { raw in
      try raw.execute(
        sql: "UPDATE \(Schema.Workspaces.tableName) SET \(Schema.Workspaces.deletedAtMs) = ? WHERE \(Schema.Workspaces.id) = ?",
        arguments: [Int64(1_716_000_000_000), workspaceID])
    }

    try db.materializeJoinedWorkspace(
      workspace: makeWorkspace(), adminMember: makeAdmin(),
      selfMember: makeSelf(), teamKey: makeKey())

    let ws = try db.readWorkspace(id: workspaceID)
    XCTAssertNil(ws?.leftAt, "left_at cleared")
    XCTAssertNil(ws?.deletedAt, "deleted_at cleared (full self-heal)")
    // Visible to the active-workspaces list (filters left + deleted).
    XCTAssertTrue(try db.listWorkspaces(includeLeft: false).contains { $0.id == workspaceID })
    XCTAssertEqual(try db.readTeamMembers(workspaceID: workspaceID).count, 2)
    XCTAssertEqual(try db.readActiveTeamKey(workspaceID: workspaceID)?.id, teamKeyID)
  }

  func testMaterialize_PreservesCreatedMetadataOnConflict() throws {
    let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    let originalCreatedAt = Date(timeIntervalSince1970: 1_690_000_000)
    try db.upsertWorkspace(Workspace(
      id: workspaceID, name: "OriginalName", createdAt: originalCreatedAt,
      createdByMemberID: "orig-creator",
      leftAt: Date(timeIntervalSince1970: 1_715_000_000)))

    // Blob carries a different createdAt/createdBy/name — conflict clause must
    // NOT overwrite created metadata or name.
    try db.materializeJoinedWorkspace(
      workspace: makeWorkspace(), adminMember: makeAdmin(),
      selfMember: makeSelf(), teamKey: makeKey())

    let ws = try db.readWorkspace(id: workspaceID)
    XCTAssertEqual(ws?.createdAt, originalCreatedAt, "created_at preserved on conflict")
    XCTAssertEqual(ws?.createdByMemberID, "orig-creator", "created_by preserved on conflict")
    XCTAssertEqual(ws?.name, "OriginalName", "name not overwritten by (possibly stale) blob name")
    XCTAssertNil(ws?.leftAt, "left_at still cleared")
  }

  // MARK: - Mode guard

  func testReaderMode_HelpersThrowDatabaseUnavailable() throws {
    let writer = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)
    try writer.upsertWorkspace(makeWorkspace())
    let reader = try Database.openForRead(at: dbURL, config: .weakDefaults, encryption: .deterministicTest)

    XCTAssertThrowsError(try reader.materializeJoinedWorkspace(
      workspace: makeWorkspace(), adminMember: makeAdmin(),
      selfMember: makeSelf(), teamKey: makeKey())) {
      XCTAssertEqual($0 as? LeafError, .databaseUnavailable)
    }
    XCTAssertThrowsError(try reader.insertTeamMemberIfAbsent(makeSelf())) {
      XCTAssertEqual($0 as? LeafError, .databaseUnavailable)
    }
  }
}
