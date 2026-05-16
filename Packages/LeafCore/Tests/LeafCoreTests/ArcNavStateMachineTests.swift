// Packages/LeafCore/Tests/LeafCoreTests/ArcNavStateMachineTests.swift
import XCTest
@testable import LeafCore

final class ArcNavStateMachineTests: XCTestCase {
    private func snap(_ key: String, _ url: String, _ title: String = "") -> TabSnapshot {
        TabSnapshot(tabKey: key, title: title, url: url)
    }

    func testColdTickSeedsWithoutEmit() {
        var sm = ArcNavStateMachine()
        let events = sm.observe(snapshots: [snap("T_a", "github.com")],
                                windowID: "W1", nowMs: 1000)
        XCTAssertEqual(events.count, 0)
    }

    func testWarmTickEmitsOnUrlChange() {
        var sm = ArcNavStateMachine()
        _ = sm.observe(snapshots: [snap("T_a", "github.com")], windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("T_a", "linear.app")], windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        guard case .tabNavigated(_, let key, let prev, let curr, _, _, _) = events[0] else {
            return XCTFail("expected tabNavigated")
        }
        XCTAssertEqual(key, "T_a")
        XCTAssertEqual(prev, "github.com")
        XCTAssertEqual(curr, "linear.app")
    }

    func testNewTabKeyDoesNotEmit() {
        var sm = ArcNavStateMachine()
        _ = sm.observe(snapshots: [snap("T_a", "github.com")], windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("T_a", "github.com"), snap("T_b", "linear.app")],
                                windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 0, "T_b is new — no prev URL to diff")
    }

    func testClosedTabDoesNotEmit() {
        var sm = ArcNavStateMachine()
        _ = sm.observe(snapshots: [snap("T_a", "github.com"), snap("T_b", "linear.app")],
                       windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("T_a", "github.com")], windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 0, "T_b closed — not a nav event")
    }

    func testMultipleTabsNavigatingEmitMultipleEvents() {
        var sm = ArcNavStateMachine()
        _ = sm.observe(snapshots: [snap("T_a", "github.com"), snap("T_b", "linear.app")],
                       windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("T_a", "github.io"), snap("T_b", "linear.io")],
                                windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 2)
    }

    func testEmptySnapshotsArrayNoEmit() {
        var sm = ArcNavStateMachine()
        _ = sm.observe(snapshots: [TabSnapshot(tabKey: "1", title: "", url: "github.com")],
                       windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [], windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 0, "empty snapshots — no nav inferred, state preserved")
    }
}
