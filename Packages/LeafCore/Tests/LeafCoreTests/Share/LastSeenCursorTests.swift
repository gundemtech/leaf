import XCTest

@testable import LeafCore

@MainActor
final class LastSeenCursorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "lastSeenCursor.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_firstRead_returnsApproximately24hAgo() {
        let cursor = LastSeenCursor(
            defaults: defaults,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let nowMs: Int64 = 1_700_000_000_000
        let expectedMs: Int64 = nowMs - (24 * 3600 * 1000)
        XCTAssertEqual(cursor.lastSeenAtMs, expectedMs)
    }

    func test_firstRead_persistsValueImmediately() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        _ = LastSeenCursor(defaults: defaults, clock: { now }).lastSeenAtMs
        let persisted = (defaults.object(forKey: "leaf.ui.lastSeenAtMs") as? NSNumber)?.int64Value
        XCTAssertEqual(persisted, 1_700_000_000_000 - (24 * 3600 * 1000))
    }

    func test_secondRead_returnsPersistedValue() {
        let cursor1 = LastSeenCursor(
            defaults: defaults,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let firstValue = cursor1.lastSeenAtMs
        let laterClock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_005_000) }
        let cursor2 = LastSeenCursor(defaults: defaults, clock: laterClock)
        XCTAssertEqual(cursor2.lastSeenAtMs, firstValue)
    }

    func test_markAllAsSeen_setsToNow() {
        let cursor = LastSeenCursor(
            defaults: defaults,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        _ = cursor.lastSeenAtMs
        cursor.markAllAsSeen(now: Date(timeIntervalSince1970: 1_700_007_200))
        XCTAssertEqual(cursor.lastSeenAtMs, 1_700_007_200_000)
    }

    func test_markAllAsSeen_persists() {
        let cursor = LastSeenCursor(
            defaults: defaults,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        cursor.markAllAsSeen(now: Date(timeIntervalSince1970: 1_700_007_200))
        let persisted = (defaults.object(forKey: "leaf.ui.lastSeenAtMs") as? NSNumber)?.int64Value
        XCTAssertEqual(persisted, 1_700_007_200_000)
    }
}
