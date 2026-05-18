//
//  FeedFilterStoreTests.swift
//  LeafCoreTests
//
//  Track 5 / S7 G.1 — TDD tests for FeedFilterStore.
//  Written before implementation so tests fail first, then pass after impl.
//

import XCTest
@testable import LeafCore

@MainActor
final class FeedFilterStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Isolated UserDefaults suiteName per test to avoid cross-test pollution.
    private func freshDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func makeStore(_ defaults: UserDefaults? = nil) -> FeedFilterStore {
        FeedFilterStore(userDefaults: defaults ?? freshDefaults())
    }

    // MARK: - G.1.1 Initial state defaults to [.all]

    func testInitial_DefaultsToAll() {
        let store = makeStore()
        XCTAssertEqual(store.selected, [.all])
    }

    // MARK: - G.1.2 Toggling .all when others are selected clears them

    func testToggleAll_ClearsOthers() async {
        let store = makeStore()
        store.toggle(.directMessages)
        XCTAssertEqual(store.selected, [.directMessages])
        // Now toggle .all — should collapse back
        store.toggle(.all)
        XCTAssertEqual(store.selected, [.all])
    }

    // MARK: - G.1.3 Selecting any other filter removes .all

    func testToggleOther_DeselectsAll() {
        let store = makeStore()
        XCTAssert(store.selected.contains(.all))
        store.toggle(.openTasks)
        XCTAssertFalse(store.selected.contains(.all))
        XCTAssert(store.selected.contains(.openTasks))
    }

    // MARK: - G.1.4 Deselecting the last non-.all filter restores [.all]

    func testToggleDeselectLast_RestoresAll() {
        let store = makeStore()
        store.toggle(.decisions)
        XCTAssertEqual(store.selected, [.decisions])
        store.toggle(.decisions)      // deselect last
        XCTAssertEqual(store.selected, [.all])
    }

    // MARK: - G.1.5 Multi-select union works correctly

    func testMultiSelectUnion() {
        let store = makeStore()
        store.toggle(.directMessages)
        store.toggle(.blockers)
        XCTAssertEqual(store.selected, [.directMessages, .blockers])
        // .all must not be present
        XCTAssertFalse(store.selected.contains(.all))
    }

    // MARK: - G.1.6 Persist + reload via UserDefaults

    func testPersistsToUserDefaults() {
        let defaults = freshDefaults()
        let store = makeStore(defaults)
        store.loadForWorkspace("ws-abc")
        store.toggle(.openTasks)
        // The raw UserDefaults key must now have data
        let key = FeedFilterStore.userDefaultsKey(workspaceID: "ws-abc")
        XCTAssertNotNil(defaults.data(forKey: key))
    }

    func testRestoreFromUserDefaults() {
        let defaults = freshDefaults()
        let store1 = makeStore(defaults)
        store1.loadForWorkspace("ws-restore")
        store1.toggle(.blockers)
        store1.toggle(.directMessages)
        let saved = store1.selected

        // New store instance, same defaults → should restore
        let store2 = makeStore(defaults)
        store2.loadForWorkspace("ws-restore")
        XCTAssertEqual(store2.selected, saved)
    }

    // MARK: - G.1.7 Switching workspaces loads different selections

    func testSwitchingWorkspaces_LoadsDifferentSelection() {
        let defaults = freshDefaults()
        let storeA = makeStore(defaults)
        storeA.loadForWorkspace("ws-A")
        storeA.toggle(.decisions)      // ws-A → [.decisions]

        let storeB = makeStore(defaults)
        storeB.loadForWorkspace("ws-B")
        storeB.toggle(.blockers)       // ws-B → [.blockers]

        // Now a third store loading ws-A should get [.decisions], not [.blockers]
        let storeA2 = makeStore(defaults)
        storeA2.loadForWorkspace("ws-A")
        XCTAssertEqual(storeA2.selected, [.decisions])

        let storeB2 = makeStore(defaults)
        storeB2.loadForWorkspace("ws-B")
        XCTAssertEqual(storeB2.selected, [.blockers])
    }

    // MARK: - G.1.8 Empty / corrupt persisted data falls back to [.all]

    func testEmptyPersistedData_FallsBackToAll() {
        let defaults = freshDefaults()
        // Write garbage data under the key
        let key = FeedFilterStore.userDefaultsKey(workspaceID: "ws-corrupt")
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: key)

        let store = makeStore(defaults)
        store.loadForWorkspace("ws-corrupt")
        XCTAssertEqual(store.selected, [.all])
    }

    // MARK: - G.1.9 clearAll resets to [.all] and persists

    func testClearAll_ResetsToAllAndPersists() {
        let defaults = freshDefaults()
        let store = makeStore(defaults)
        store.loadForWorkspace("ws-clear")
        store.toggle(.openTasks)
        store.toggle(.blockers)
        XCTAssert(store.selected.count == 2)

        store.clearAll()
        XCTAssertEqual(store.selected, [.all])

        // Verify persisted state is also [.all] by restoring in a fresh instance
        let store2 = makeStore(defaults)
        store2.loadForWorkspace("ws-clear")
        XCTAssertEqual(store2.selected, [.all])
    }

    // MARK: - G.1.10 ShareSource round-trip through persist + restore

    func testCodableShareSource_RoundTrips() {
        let defaults = freshDefaults()
        let store1 = makeStore(defaults)
        store1.loadForWorkspace("ws-src")
        store1.toggle(.shareSource(.gitCommits))
        store1.toggle(.shareSource(.linearIssues))
        let saved = store1.selected

        let store2 = makeStore(defaults)
        store2.loadForWorkspace("ws-src")
        XCTAssertEqual(store2.selected, saved)
        XCTAssert(store2.selected.contains(.shareSource(.gitCommits)))
        XCTAssert(store2.selected.contains(.shareSource(.linearIssues)))
        XCTAssertFalse(store2.selected.contains(.all))
    }
}
