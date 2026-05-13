import XCTest
import GRDB
@testable import LeafCore

/// Track-5 S2 — fresh-DB migration. Asserts post-M019 schema shape: workspaces
/// table with `left_at_ms`, `team_members.workspace_id` (renamed), `workspace_id`
/// columns on team_keys / rotation_outbox / pending_invites, renamed index,
/// and that the legacy `org` table no longer exists.
final class M019_FreshDBMigrationTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("m019-fresh-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testFreshDB_AllSchemaPresent() throws {
        let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)

        // workspaces — renamed table + new left_at_ms column.
        let wsCols = try db.fetchTableColumns("workspaces")
        XCTAssertTrue(wsCols.contains("id"))
        XCTAssertTrue(wsCols.contains("name"))
        XCTAssertTrue(wsCols.contains("created_at_ms"))
        XCTAssertTrue(wsCols.contains("created_by_member_id"))
        XCTAssertTrue(wsCols.contains("left_at_ms"))

        // team_members — workspace_id replaces org_id (column rename).
        let tmCols = try db.fetchTableColumns("team_members")
        XCTAssertTrue(tmCols.contains("workspace_id"))
        XCTAssertFalse(tmCols.contains("org_id"), "org_id should be renamed → workspace_id")

        // team_keys — workspace_id added.
        XCTAssertTrue(try db.fetchTableColumns("team_keys").contains("workspace_id"))

        // rotation_outbox + pending_invites — workspace_id added.
        XCTAssertTrue(try db.fetchTableColumns("rotation_outbox").contains("workspace_id"))
        XCTAssertTrue(try db.fetchTableColumns("pending_invites").contains("workspace_id"))

        // Index renamed: team_members_org_active → team_members_workspace_active.
        let tmIndexes = try db.fetchTableIndexes("team_members")
        XCTAssertTrue(tmIndexes.contains("team_members_workspace_active"))
        XCTAssertFalse(tmIndexes.contains("team_members_org_active"),
                       "Old index name should be dropped by M019")

        // Legacy `org` table renamed away — should not exist.
        XCTAssertFalse(try db.tableExists("org"), "M019 renames org → workspaces")
    }
}
