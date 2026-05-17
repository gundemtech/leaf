import XCTest

@testable import LeafCore

final class AppleScriptPermissionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    @MainActor
    override func setUp() async throws {
        suiteName = "applescript.permission.test.suite.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testInitialStateIsNotRequested() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        if case .notRequested = store.cachedState(for: "com.example.app") {
        } else {
            XCTFail("expected .notRequested")
        }
    }

    @MainActor
    func testRecordGrantedPersists() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        store.record(.granted, for: "com.example.app", nowMs: 1_000_000)
        if case .granted = store.cachedState(for: "com.example.app") {
        } else {
            XCTFail("expected .granted after record")
        }
        let store2 = AppleScriptPermissionStore(defaults: defaults)
        if case .granted = store2.cachedState(for: "com.example.app") {
        } else {
            XCTFail("expected .granted persisted across instances")
        }
    }

    @MainActor
    func testRecordDeniedPersistsWithTimestamp() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        store.record(.denied(2_000_000), for: "com.example.app", nowMs: 2_000_000)
        if case .denied(let t) = store.cachedState(for: "com.example.app") {
            XCTAssertEqual(t, 2_000_000)
        } else {
            XCTFail("expected .denied(t)")
        }
    }

    @MainActor
    func testShouldProbeFalseForRecentDeny() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        let denialMs: Int64 = 1_000_000
        store.record(.denied(denialMs), for: "com.example.app", nowMs: denialMs)
        let withinWindowMs = denialMs + 12 * 3600 * 1000
        XCTAssertFalse(store.shouldProbe(for: "com.example.app", nowMs: withinWindowMs))
    }

    @MainActor
    func testShouldProbeTrueAfter24h() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        let denialMs: Int64 = 1_000_000
        store.record(.denied(denialMs), for: "com.example.app", nowMs: denialMs)
        let afterWindowMs = denialMs + 24 * 3600 * 1000 + 1
        XCTAssertTrue(store.shouldProbe(for: "com.example.app", nowMs: afterWindowMs))
    }

    @MainActor
    func testShouldProbeTrueForNotRequested() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        XCTAssertTrue(store.shouldProbe(for: "com.example.app", nowMs: 1_000_000))
    }

    @MainActor
    func testShouldProbeTrueForGranted() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        store.record(.granted, for: "com.example.app", nowMs: 1_000_000)
        XCTAssertTrue(store.shouldProbe(for: "com.example.app", nowMs: 1_500_000))
    }

    @MainActor
    func testUnavailableTerminalState() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        store.record(.unavailable, for: "com.example.app", nowMs: 1_000_000)
        if case .unavailable = store.cachedState(for: "com.example.app") {
        } else {
            XCTFail("expected .unavailable")
        }
        XCTAssertFalse(store.shouldProbe(for: "com.example.app", nowMs: 5_000_000))
    }

    @MainActor
    func testAppNotInstalledTerminalState() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        store.record(.appNotInstalled, for: "com.example.app", nowMs: 1_000_000)
        if case .appNotInstalled = store.cachedState(for: "com.example.app") {
        } else {
            XCTFail("expected .appNotInstalled")
        }
        XCTAssertFalse(store.shouldProbe(for: "com.example.app", nowMs: 5_000_000))
    }

    @MainActor
    func testGrantedClearsDeniedTimestamp() {
        let store = AppleScriptPermissionStore(defaults: defaults)
        store.record(.denied(1_000_000), for: "com.example.app", nowMs: 1_000_000)
        store.record(.granted, for: "com.example.app", nowMs: 2_000_000)
        // Switch back to denied with new timestamp; should reflect new value
        store.record(.denied(3_000_000), for: "com.example.app", nowMs: 3_000_000)
        if case .denied(let t) = store.cachedState(for: "com.example.app") {
            XCTAssertEqual(t, 3_000_000)
        } else {
            XCTFail("expected fresh .denied(3M)")
        }
    }
}
