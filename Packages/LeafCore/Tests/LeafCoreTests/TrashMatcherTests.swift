import XCTest

@testable import LeafCore

final class TrashMatcherTests: XCTestCase {

    func testSingleAddedEmits() {
        var matcher = TrashMatcher()
        XCTAssertEqual(
            matcher.observe(addedCount: 1, removedCount: 0, nowMs: 1_000_000),
            .added
        )
    }

    func testBurstRemovedEmitsEmptied() {
        var matcher = TrashMatcher()
        XCTAssertEqual(
            matcher.observe(addedCount: 0, removedCount: 50, nowMs: 1_000_000),
            .emptied
        )
    }

    func testCoalesceWithinWindow() {
        var matcher = TrashMatcher(coalesceWindowMs: 2_000)
        _ = matcher.observe(addedCount: 1, removedCount: 0, nowMs: 1_000_000)
        XCTAssertNil(
            matcher.observe(addedCount: 1, removedCount: 0, nowMs: 1_001_500),
            "second emission within 2s window must be coalesced"
        )
    }

    func testCoalesceReleasesAfterWindow() {
        var matcher = TrashMatcher(coalesceWindowMs: 2_000)
        _ = matcher.observe(addedCount: 1, removedCount: 0, nowMs: 1_000_000)
        XCTAssertEqual(
            matcher.observe(addedCount: 1, removedCount: 0, nowMs: 1_002_500),
            .added,
            "emission past 2s window must fire"
        )
    }

    func testMixedBatchPrefersAdded() {
        var matcher = TrashMatcher()
        // 5 added, 3 removed — removed below burst threshold (>10) → .added.
        XCTAssertEqual(
            matcher.observe(addedCount: 5, removedCount: 3, nowMs: 1_000_000),
            .added
        )
    }
}
