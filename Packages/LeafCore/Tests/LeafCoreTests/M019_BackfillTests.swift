import XCTest
import GRDB
@testable import LeafCore

/// Track-5 S2 — backfill semantics on alpha.x-shape data. Asserts that an
/// existing `org` row with linked team_members + team_keys survives the M019
/// rename + ALTER ADD COLUMN steps, and that the backfilled `workspace_id`
/// columns point at the (renamed) workspaces row's id.
final class M019_BackfillTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("m019-backfill-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    /// Simulate alpha.x-shape: 1 org + 2 team_members (admin + member) + 1
    /// team_keys. After M019, all child rows should have workspace_id = that
    /// org's id (column rename for team_members; ADD COLUMN DEFAULT backfill
    /// for team_keys).
    func testAlphaXBackfill_PreservesData() throws {
        // Step A — open pool, register migrations up to M018 only.
        let pool = try DatabasePool(path: tempURL.path)
        var migrator18 = DatabaseMigrator()
        migrator18.registerMigration001Events()
        migrator18.registerMigration002CollectorOffsets()
        migrator18.registerMigration003WatchedFolders()
        migrator18.registerMigration004Integrations()
        migrator18.registerMigration005PresenceState()
        migrator18.registerMigration006Org()
        migrator18.registerMigration007TeamMembers()
        migrator18.registerMigration008TeamKeys()
        migrator18.registerMigration009RotationOutbox()
        migrator18.registerMigration010PendingInvites()
        migrator18.registerMigration011EventKindIndex()
        migrator18.registerMigration012EventsFTS()
        migrator18.registerMigration013EventLinks()
        migrator18.registerMigration014DetectionTables()
        migrator18.registerMigration015ProviderSnapshots()
        migrator18.registerMigration016NormalizeGitHubEventKinds()
        migrator18.registerMigration017NormalizeSlackEventKinds()
        migrator18.registerMigration018IntensityAggregates()
        try migrator18.migrate(pool)

        // Step B — insert alpha.x-shape rows directly into pre-M019 schema.
        let orgUUID = "alpha-org-uuid"
        let adminID = "admin-member-uuid"
        let memberID = "regular-member-uuid"
        let keyID = "first-team-key-uuid"
        let nowMs: Int64 = 1_700_000_000_000

        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO org (id, name, created_at_ms, created_by_member_id)
                VALUES (?, ?, ?, ?)
                """, arguments: [orgUUID, "AlphaTeam", nowMs, adminID])

            try db.execute(sql: """
                INSERT INTO team_members (id, org_id, role, pubkey_hex, display_name, added_at_ms, removed_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """, arguments: [adminID, orgUUID, "admin",
                                 "deadbeef" + String(repeating: "00", count: 28),
                                 "Anton", nowMs])

            try db.execute(sql: """
                INSERT INTO team_members (id, org_id, role, pubkey_hex, display_name, added_at_ms, removed_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """, arguments: [memberID, orgUUID, "member",
                                 "cafebabe" + String(repeating: "00", count: 28),
                                 "Dima", nowMs])

            try db.execute(sql: """
                INSERT INTO team_keys (id, generated_at_ms, deprecated_at_ms, generated_by_member_id)
                VALUES (?, ?, NULL, ?)
                """, arguments: [keyID, nowMs, adminID])
        }

        // Step C — apply M019.
        var migrator19 = migrator18
        migrator19.registerMigration019Workspaces()
        try migrator19.migrate(pool)

        // Step D — assertions.
        try pool.read { db in
            // workspaces row preserves original org's id + name; left_at_ms NULL.
            let wsRow = try Row.fetchOne(db, sql: "SELECT * FROM workspaces WHERE id = ?",
                                          arguments: [orgUUID])
            XCTAssertNotNil(wsRow, "workspaces row should preserve original org id")
            XCTAssertEqual(wsRow?["name"] as String?, "AlphaTeam")
            XCTAssertNil(wsRow?["left_at_ms"] as Int64?, "left_at_ms should be NULL")

            // team_members: column rename preserves linkage to orgUUID.
            let tmCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM team_members WHERE workspace_id = ?
                """, arguments: [orgUUID]) ?? -1
            XCTAssertEqual(tmCount, 2,
                           "Both team_members rows should keep their workspace_id after rename")

            // team_keys: ADD COLUMN DEFAULT backfills workspace_id to orgUUID.
            let tkWid = try String.fetchOne(db, sql: """
                SELECT workspace_id FROM team_keys WHERE id = ?
                """, arguments: [keyID])
            XCTAssertEqual(tkWid, orgUUID,
                           "team_keys workspace_id should be backfilled to org's id")
        }
    }
}
