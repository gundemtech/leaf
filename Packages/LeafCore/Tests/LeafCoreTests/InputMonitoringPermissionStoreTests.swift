import XCTest
@testable import LeafCore

final class InputMonitoringPermissionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "inputMonitoring.test.suite.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNotRequestedDefault() {
        let store = InputMonitoringPermissionStore(defaults: defaults)
        XCTAssertEqual(store.cachedState(), .notRequested)
        XCTAssertTrue(store.shouldProbe(nowMs: 1_000))
    }

    func testGrantedRoundTrip() {
        let store = InputMonitoringPermissionStore(defaults: defaults)
        store.record(.granted, nowMs: 1_000)
        XCTAssertEqual(store.cachedState(), .granted)
        XCTAssertTrue(store.shouldProbe(nowMs: 2_000),
                      "granted re-probes (revoke detection)")
    }

    func testDeniedRoundTripPreservesTimestamp() {
        let store = InputMonitoringPermissionStore(defaults: defaults)
        store.record(.denied(5_000), nowMs: 5_000)
        XCTAssertEqual(store.cachedState(), .denied(5_000))
    }

    func testDenialBackoff24h() {
        let store = InputMonitoringPermissionStore(defaults: defaults)
        store.record(.denied(0), nowMs: 0)
        XCTAssertFalse(store.shouldProbe(nowMs: 24 * 3600 * 1000 - 1),
                       "within 24h must not re-probe")
        XCTAssertTrue(store.shouldProbe(nowMs: 24 * 3600 * 1000 + 1),
                      "past 24h must re-probe")
    }

    func testUnavailableTerminal() {
        let store = InputMonitoringPermissionStore(defaults: defaults)
        store.record(.unavailable, nowMs: 0)
        XCTAssertEqual(store.cachedState(), .unavailable)
        XCTAssertFalse(store.shouldProbe(nowMs: 1_000_000),
                       "unavailable terminal — never re-probes")
    }
}
