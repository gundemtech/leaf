import XCTest
import CryptoKit
@testable import LeafCore

/// Track-5 S2 — multi-workspace domain service. Mirrors OrgServiceTests
/// pattern but exercises N-workspace surface and the new
/// `WorkspaceService.{createWorkspace, readWorkspace, listWorkspaces}` API.
/// markLeft + rejoin live in Task 11 (OQ-T5-2 resolution).
final class WorkspaceServiceTests: XCTestCase {
    private var tempDir: URL!
    private var keystoreRoot: URL!
    private var dbURL: URL!
    private var db: Database!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-svc-\(UUID().uuidString)")
        keystoreRoot = tempDir.appendingPathComponent("keystore", isDirectory: true)
        dbURL = tempDir.appendingPathComponent("events.sqlite")
        db = try! Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeService(
        now: Date = Date(timeIntervalSince1970: 1_700_000_000),
        randomUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) -> WorkspaceService {
        WorkspaceService(
            database: db,
            keystoreRoot: keystoreRoot,
            now: { now },
            randomBytes: { count in Data(repeating: 0x42, count: count) },
            randomUUID: randomUUID
        )
    }

    // MARK: - createWorkspace

    func testCreateWorkspace_WritesAllThreeRows() throws {
        let svc = makeService()
        let workspace = try svc.createWorkspace(displayName: "Acme")

        XCTAssertEqual(try db.readWorkspace(id: workspace.id)?.name, "Acme")
        let members = try db.readTeamMembers(workspaceID: workspace.id)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.role, .admin)
        let teamKey = try db.readActiveTeamKey(workspaceID: workspace.id)
        XCTAssertNotNil(teamKey)
        XCTAssertEqual(teamKey?.workspaceID, workspace.id)
    }

    func testCreateTwoWorkspacesSameName_BothExist() throws {
        let svc = makeService()
        let w1 = try svc.createWorkspace(displayName: "Acme")
        let w2 = try svc.createWorkspace(displayName: "Acme")
        XCTAssertNotEqual(w1.id, w2.id)
        let all = try svc.listWorkspaces()
        XCTAssertEqual(Set(all.map(\.id)), Set([w1.id, w2.id]))
    }

    func testCreateWorkspace_TrimsDisplayName() throws {
        let svc = makeService()
        let workspace = try svc.createWorkspace(displayName: "   Acme  ")
        XCTAssertEqual(workspace.name, "Acme")
    }

    func testCreateWorkspace_EmptyName_Throws() throws {
        let svc = makeService()
        XCTAssertThrowsError(try svc.createWorkspace(displayName: "   "))
    }

    func testCreateWorkspace_WritesKeystoreFile() throws {
        let svc = makeService()
        let workspace = try svc.createWorkspace(displayName: "Acme")
        let teamKey = try XCTUnwrap(try db.readActiveTeamKey(workspaceID: workspace.id))
        let onDisk = try TeamKeystore.readTeamKey(
            workspaceID: workspace.id,
            keyID: teamKey.id,
            at: keystoreRoot
        )
        XCTAssertEqual(onDisk.count, 32)
    }

    // MARK: - readWorkspace / listWorkspaces

    func testReadWorkspace_NotFound_ReturnsNil() throws {
        let svc = makeService()
        XCTAssertNil(try svc.readWorkspace(id: "nonexistent"))
    }

    func testListWorkspaces_Empty_ReturnsEmpty() throws {
        let svc = makeService()
        XCTAssertEqual(try svc.listWorkspaces(), [])
    }

    func testListWorkspaces_OrderedByCreatedAt() throws {
        let early = makeService(now: Date(timeIntervalSince1970: 1_700_000_000))
        let w1 = try early.createWorkspace(displayName: "First")
        let late = makeService(now: Date(timeIntervalSince1970: 1_700_000_100))
        let w2 = try late.createWorkspace(displayName: "Second")
        let listed = try early.listWorkspaces()
        XCTAssertEqual(listed.map(\.id), [w1.id, w2.id])
    }

    // MARK: - markLeft / rejoin (OQ-T5-2)

    func testMarkLeft_SetsLeftAtMs() throws {
        let svc = makeService(now: Date(timeIntervalSince1970: 1_700_000_000))
        let workspace = try svc.createWorkspace(displayName: "ToBeLeft")
        try svc.markLeft(workspaceID: workspace.id, at: Date(timeIntervalSince1970: 1_700_000_100))
        let updated = try XCTUnwrap(try svc.readWorkspace(id: workspace.id))
        XCTAssertNotNil(updated.leftAt)
        XCTAssertEqual(updated.leftAt?.timeIntervalSince1970, 1_700_000_100)
    }

    func testMarkLeft_HidesFromDefaultList() throws {
        let svc = makeService()
        let w1 = try svc.createWorkspace(displayName: "Active")
        let w2 = try svc.createWorkspace(displayName: "Left")
        try svc.markLeft(workspaceID: w2.id, at: Date())

        let active = try svc.listWorkspaces()
        XCTAssertEqual(active.map(\.id), [w1.id])

        let all = try svc.listWorkspaces(includeLeft: true)
        XCTAssertEqual(Set(all.map(\.id)), Set([w1.id, w2.id]))
    }

    func testMarkLeft_Idempotent_PreservesOriginalTimestamp() throws {
        let svc = makeService()
        let w = try svc.createWorkspace(displayName: "X")
        let firstLeft = Date(timeIntervalSince1970: 1_700_000_100)
        try svc.markLeft(workspaceID: w.id, at: firstLeft)
        try svc.markLeft(workspaceID: w.id, at: Date(timeIntervalSince1970: 1_900_000_000))
        let updated = try XCTUnwrap(try svc.readWorkspace(id: w.id))
        XCTAssertEqual(updated.leftAt?.timeIntervalSince1970, firstLeft.timeIntervalSince1970,
                       "Re-mark should preserve original leftAt")
    }

    func testMarkLeft_Missing_Throws() throws {
        let svc = makeService()
        XCTAssertThrowsError(try svc.markLeft(workspaceID: "nonexistent", at: Date()))
    }

    func testRejoin_ClearsLeftAt() throws {
        let svc = makeService()
        let w = try svc.createWorkspace(displayName: "X")
        try svc.markLeft(workspaceID: w.id, at: Date())
        try svc.rejoin(workspaceID: w.id)
        let updated = try XCTUnwrap(try svc.readWorkspace(id: w.id))
        XCTAssertNil(updated.leftAt)
        // Re-appears in default list.
        XCTAssertEqual(try svc.listWorkspaces().count, 1)
    }

    func testRejoin_NotLeft_NoOp() throws {
        let svc = makeService()
        let w = try svc.createWorkspace(displayName: "X")
        XCTAssertNoThrow(try svc.rejoin(workspaceID: w.id))
        let updated = try XCTUnwrap(try svc.readWorkspace(id: w.id))
        XCTAssertNil(updated.leftAt)
    }
}
