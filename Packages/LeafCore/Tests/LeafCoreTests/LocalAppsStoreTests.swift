import XCTest
@testable import LeafCore

final class LocalAppsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "localApps.test.suite.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testInitialEnabledIsFalse() {
        let store = LocalAppsStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled("com.apple.Music"))
    }


    func testSetEnabledPersists() {
        let store = LocalAppsStore(defaults: defaults)
        store.setEnabled("com.apple.Music", true)
        XCTAssertTrue(store.isEnabled("com.apple.Music"))
        let store2 = LocalAppsStore(defaults: defaults)
        XCTAssertTrue(store2.isEnabled("com.apple.Music"))
    }


    func testEnabledToggleIsIndependentAcrossBundles() {
        let store = LocalAppsStore(defaults: defaults)
        store.setEnabled("com.apple.Music", true)
        XCTAssertTrue(store.isEnabled("com.apple.Music"))
        XCTAssertFalse(store.isEnabled("com.spotify.client"))
        store.setEnabled("com.apple.Music", false)
        XCTAssertFalse(store.isEnabled("com.apple.Music"))
    }


    func testSubFieldOptedInDefaultFalse() {
        let store = LocalAppsStore(defaults: defaults)
        XCTAssertFalse(store.isSubFieldOptedIn("com.apple.mail", field: "mailboxName"))
    }


    func testSetSubFieldOptInPersistsAndIsScoped() {
        let store = LocalAppsStore(defaults: defaults)
        store.setSubFieldOptedIn("com.apple.mail", field: "mailboxName", optedIn: true)
        XCTAssertTrue(store.isSubFieldOptedIn("com.apple.mail", field: "mailboxName"))
        XCTAssertFalse(store.isSubFieldOptedIn("us.zoom.xos", field: "ownMeetingTopic"))
        // New instance reads from defaults
        let store2 = LocalAppsStore(defaults: defaults)
        XCTAssertTrue(store2.isSubFieldOptedIn("com.apple.mail", field: "mailboxName"))
    }
}
