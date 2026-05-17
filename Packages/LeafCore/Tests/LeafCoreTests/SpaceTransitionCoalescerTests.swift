import XCTest

@testable import LeafCore

final class SpaceTransitionCoalescerTests: XCTestCase {

    /// #1 — first observation always emits.
    func testFirstObservationEmits() {
        var c = SpaceTransitionCoalescer(coalesceWindowMs: 2_000)
        XCTAssertTrue(c.observe(nowMs: 1_000))
    }

    /// #2 — observation within coalesce window drops.
    func testWithinWindowDrops() {
        var c = SpaceTransitionCoalescer(coalesceWindowMs: 2_000)
        _ = c.observe(nowMs: 1_000)
        XCTAssertFalse(c.observe(nowMs: 2_000))  // 1000ms later, within 2000ms
        XCTAssertFalse(c.observe(nowMs: 2_999))  // still within
    }

    /// #3 — observation past coalesce window emits.
    func testPastWindowEmits() {
        var c = SpaceTransitionCoalescer(coalesceWindowMs: 2_000)
        _ = c.observe(nowMs: 1_000)
        XCTAssertTrue(c.observe(nowMs: 3_001))  // 2001ms later
    }

    /// #4 — emit resets the window from the emit timestamp.
    func testEmitResetsWindow() {
        var c = SpaceTransitionCoalescer(coalesceWindowMs: 2_000)
        _ = c.observe(nowMs: 1_000)
        XCTAssertTrue(c.observe(nowMs: 4_000))  // emit at 4000
        XCTAssertFalse(c.observe(nowMs: 5_000))  // 1000ms after 4000, within window
        XCTAssertTrue(c.observe(nowMs: 6_001))  // 2001ms after 4000
    }
}
