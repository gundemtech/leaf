import XCTest

@testable import LeafCore

// swiftlint:disable force_unwrapping
// Reason: test fixtures rely on force-unwrap for setup convenience —
// URL literals, HTTPURLResponse construction, decoded JSON, post-`try`
// DB reads where nil ⇒ broken test, not production semantic.

final class AIToolsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "leaf.tests.aitools.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testDefaultValuesAreFalse() {
        let store = AIToolsStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled("claude_code"))
        XCTAssertFalse(store.isEnabled("claude_code.tokens"))
        XCTAssertFalse(store.isEnabled("some_other_feature"))
    }

    func testSetEnabledPersists() {
        let store = AIToolsStore(defaults: defaults)
        store.setEnabled("claude_code", true)
        XCTAssertTrue(store.isEnabled("claude_code"))
        // Sibling key untouched.
        XCTAssertFalse(store.isEnabled("claude_code.tokens"))

        store.setEnabled("claude_code", false)
        XCTAssertFalse(store.isEnabled("claude_code"))
    }

    func testKeyPrefixIsolation() {
        // Verify keys are namespaced under `leaf.aitools.` to avoid colliding
        // with LocalAppsStore (`localApps.enabled.*`) etc.
        let store = AIToolsStore(defaults: defaults)
        store.setEnabled("claude_code", true)
        XCTAssertTrue(defaults.bool(forKey: "leaf.aitools.claude_code"))
        XCTAssertFalse(defaults.bool(forKey: "claude_code"))
        XCTAssertFalse(defaults.bool(forKey: "localApps.enabled.claude_code"))
    }

    func testLastInstallResultDefault() {
        let store = AIToolsStore(defaults: defaults)
        XCTAssertEqual(store.lastInstallResult, .notAttempted)
        store.lastInstallResult = .ok
        XCTAssertEqual(store.lastInstallResult, .ok)
        store.lastInstallResult = .failed("test")
        XCTAssertEqual(store.lastInstallResult, .failed("test"))
    }
}
// swiftlint:enable force_unwrapping
