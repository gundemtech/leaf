import XCTest
@testable import LeafCore

/// Track-5 S2 — round-trips `WorkspaceService.createWorkspace` through a
/// DB reopen, and asserts that two workspaces on the same device land in
/// disjoint `team_members` rows (workspace_id scoping).
final class WorkspacePersistenceIntegrationTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-persist-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testCreateWorkspace_ReopenDB_DataPreserved() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let keystoreRoot = tempDir.appendingPathComponent("keystore")

        // Create + drop the first connection.
        do {
            let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
            let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
            _ = try svc.createWorkspace(displayName: "PersistedTeam")
        }

        // Reopen and assert workspace row + active teamKey readable from disk.
        let db2 = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
        let workspaces = try db2.listWorkspaces()
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces.first?.name, "PersistedTeam")

        let teamKey = try XCTUnwrap(try db2.readActiveTeamKey(workspaceID: workspaces.first!.id))
        let bytes = try TeamKeystore.readTeamKey(
            workspaceID: workspaces.first!.id,
            keyID: teamKey.id,
            at: keystoreRoot
        )
        XCTAssertEqual(bytes.count, 32)
    }

    func testTwoWorkspaces_SeparateMembers() throws {
        let dbURL = tempDir.appendingPathComponent("events.sqlite")
        let keystoreRoot = tempDir.appendingPathComponent("keystore")
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
        let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)

        let w1 = try svc.createWorkspace(displayName: "Acme")
        let w2 = try svc.createWorkspace(displayName: "Globex")

        // Each workspace has its own admin row.
        XCTAssertEqual(try db.readTeamMembers(workspaceID: w1.id).count, 1)
        XCTAssertEqual(try db.readTeamMembers(workspaceID: w2.id).count, 1)

        // Members of w1 are NOT visible to w2 query.
        let w1Members = try db.readTeamMembers(workspaceID: w1.id)
        let w2Members = try db.readTeamMembers(workspaceID: w2.id)
        XCTAssertNotEqual(w1Members.first?.id, w2Members.first?.id)
    }
}
