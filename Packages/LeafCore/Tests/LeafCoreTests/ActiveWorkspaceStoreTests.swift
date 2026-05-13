import XCTest
@testable import LeafCore

/// Track-5 S2 — `ActiveWorkspaceStore` @Observable wrapper around the
/// `leaf.active_workspace_id` UserDefaults key. Covers init defaults,
/// persistence, nil-clear semantics, and the post-M019 backfill helper
/// (resolves to oldest workspace; idempotent on existing selection).
@MainActor
final class ActiveWorkspaceStoreTests: XCTestCase {
    private var testSuiteName: String!
    private var ud: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        testSuiteName = "leaf.activeworkspacestore.test.\(UUID().uuidString)"
        ud = UserDefaults(suiteName: testSuiteName)!
    }

    override func tearDown() async throws {
        ud.removePersistentDomain(forName: testSuiteName)
        ud = nil
        try await super.tearDown()
    }

    func testInit_DefaultsToNil() {
        let store = ActiveWorkspaceStore(userDefaults: ud)
        XCTAssertNil(store.activeWorkspaceID)
    }

    func testInit_LoadsFromUserDefaults() {
        ud.set("ws-1", forKey: "leaf.active_workspace_id")
        let store = ActiveWorkspaceStore(userDefaults: ud)
        XCTAssertEqual(store.activeWorkspaceID, "ws-1")
    }

    func testSetActive_Persists() {
        let store = ActiveWorkspaceStore(userDefaults: ud)
        store.setActive("ws-2")
        XCTAssertEqual(store.activeWorkspaceID, "ws-2")
        XCTAssertEqual(ud.string(forKey: "leaf.active_workspace_id"), "ws-2")
    }

    func testSetActive_Nil_Clears() {
        ud.set("ws-existing", forKey: "leaf.active_workspace_id")
        let store = ActiveWorkspaceStore(userDefaults: ud)
        store.setActive(nil)
        XCTAssertNil(store.activeWorkspaceID)
        XCTAssertNil(ud.string(forKey: "leaf.active_workspace_id"))
    }

    func testBackfillIfNeeded_NoWorkspaces_NoOp() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aws-backfill-empty-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
        let store = ActiveWorkspaceStore(userDefaults: ud)
        try store.backfillIfNeeded(database: db)
        XCTAssertNil(store.activeWorkspaceID)
    }

    func testBackfillIfNeeded_ResolvesToOldestWorkspace() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aws-backfill-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)

        try db.upsertWorkspace(Workspace(
            id: "w-newer",
            name: "Newer",
            createdAt: Date(timeIntervalSince1970: 2_000_000_000),
            createdByMemberID: "m-1"
        ))
        try db.upsertWorkspace(Workspace(
            id: "w-older",
            name: "Older",
            createdAt: Date(timeIntervalSince1970: 1_000_000_000),
            createdByMemberID: "m-2"
        ))

        let store = ActiveWorkspaceStore(userDefaults: ud)
        try store.backfillIfNeeded(database: db)
        XCTAssertEqual(store.activeWorkspaceID, "w-older")
    }

    func testBackfillIfNeeded_Idempotent() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aws-idem-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let db = try Database.openForWrite(at: tempURL, config: .weakDefaults, encryption: nil)
        try db.upsertWorkspace(Workspace(
            id: "w-1",
            name: "Solo",
            createdAt: Date(timeIntervalSince1970: 1_000_000_000),
            createdByMemberID: "m-1"
        ))

        let store = ActiveWorkspaceStore(userDefaults: ud)
        store.setActive("user-chose-this")
        try store.backfillIfNeeded(database: db)
        // Already set → no overwrite.
        XCTAssertEqual(store.activeWorkspaceID, "user-chose-this")
    }
}
