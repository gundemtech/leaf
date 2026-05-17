// Packages/LeafCore/Tests/LeafCoreTests/SafariNavStateMachineTests.swift
import XCTest

@testable import LeafCore

final class SafariNavStateMachineTests: XCTestCase {
    private func snap(_ key: String, _ url: String, _ title: String = "") -> TabSnapshot {
        TabSnapshot(tabKey: key, title: title, url: url)
    }

    func testColdTickSeedsWithoutEmit() {
        var sm = SafariNavStateMachine()
        let events = sm.observe(
            snapshots: [snap("i1", "github.com")],
            windowID: "W1", nowMs: 1000)
        XCTAssertEqual(events.count, 0)
    }

    func testWarmTickEmitsOnUrlChange() {
        var sm = SafariNavStateMachine()
        _ = sm.observe(snapshots: [snap("i1", "github.com")], windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("i1", "linear.app")], windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        guard case .tabNavigated(_, let key, let prev, let curr, _, _, _) = events[0] else {
            return XCTFail("expected tabNavigated")
        }
        XCTAssertEqual(key, "i1")
        XCTAssertEqual(prev, "github.com")
        XCTAssertEqual(curr, "linear.app")
    }

    func testNewTabKeyDoesNotEmit() {
        var sm = SafariNavStateMachine()
        _ = sm.observe(snapshots: [snap("i1", "github.com")], windowID: "W1", nowMs: 1000)
        let events = sm.observe(
            snapshots: [snap("i1", "github.com"), snap("i2", "linear.app")],
            windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 0, "i2 is new — no prev URL to diff")
    }

    func testClosedTabDoesNotEmit() {
        var sm = SafariNavStateMachine()
        _ = sm.observe(
            snapshots: [snap("i1", "github.com"), snap("i2", "linear.app")],
            windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("i1", "github.com")], windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 0, "i2 closed — not a nav event")
    }

    func testMultipleTabsNavigatingEmitMultipleEvents() {
        var sm = SafariNavStateMachine()
        _ = sm.observe(
            snapshots: [snap("i1", "github.com"), snap("i2", "linear.app")],
            windowID: "W1", nowMs: 1000)
        let events = sm.observe(
            snapshots: [snap("i1", "github.io"), snap("i2", "linear.io")],
            windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 2)
    }
}
