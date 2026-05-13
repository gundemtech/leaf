import XCTest
@testable import LeafCore

final class SystemObserversStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "systemObservers.test.suite.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testIntensityDefaultsOff() {
        let store = SystemObserversStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled("intensity"))
    }

    func testNonIntensityDefaultsOn() {
        let store = SystemObserversStore(defaults: defaults)
        for observer in SystemObserversStore.allObservers where observer != "intensity" {
            XCTAssertTrue(store.isEnabled(observer), "\(observer) must default ON")
        }
    }

    func testSetEnabledRoundTrip() {
        let store = SystemObserversStore(defaults: defaults)
        store.setEnabled("intensity", true)
        XCTAssertTrue(store.isEnabled("intensity"))
        store.setEnabled("clipboard", false)
        XCTAssertFalse(store.isEnabled("clipboard"))
    }

    func testCrossInstanceVisibility() {
        let writer = SystemObserversStore(defaults: defaults)
        writer.setEnabled("intensity", true)
        // Fresh reader instance reads the same UserDefaults domain — no cache hit.
        let reader = SystemObserversStore(defaults: defaults)
        XCTAssertTrue(reader.isEnabled("intensity"))
    }

    func testAllObserversCount() {
        XCTAssertEqual(SystemObserversStore.allObservers.count, 10)
        XCTAssertEqual(Set(SystemObserversStore.allObservers).count, 10,
                       "Observer names must be unique")
    }

    func testKeyPrefix() {
        XCTAssertEqual(SystemObserversStore.key("intensity"),
                       "systemObservers.intensity.enabled")
        XCTAssertEqual(SystemObserversStore.key("downloads_watcher"),
                       "systemObservers.downloads_watcher.enabled")
    }
}
