// Packages/LeafCore/Tests/LeafCoreTests/ChromeNavStateMachineTests.swift
import XCTest
@testable import LeafCore

final class ChromeNavStateMachineTests: XCTestCase {
    private func snap(_ key: String, _ url: String, _ title: String = "") -> TabSnapshot {
        TabSnapshot(tabKey: key, title: title, url: url)
    }

    func testColdTickSeedsWithoutEmit() {
        var sm = ChromeNavStateMachine()
        let events = sm.observe(snapshots: [snap("42", "github.com")],
                                windowID: "W1", nowMs: 1000)
        XCTAssertEqual(events.count, 0)
    }

    func testWarmTickEmitsOnUrlChange() {
        var sm = ChromeNavStateMachine()
        _ = sm.observe(snapshots: [snap("42", "github.com")], windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("42", "linear.app")], windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        guard case .tabNavigated(_, let key, let prev, let curr, _, _, _) = events[0] else {
            return XCTFail("expected tabNavigated")
        }
        XCTAssertEqual(key, "42")
        XCTAssertEqual(prev, "github.com")
        XCTAssertEqual(curr, "linear.app")
    }

    func testNewTabKeyDoesNotEmit() {
        var sm = ChromeNavStateMachine()
        _ = sm.observe(snapshots: [snap("42", "github.com")], windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("42", "github.com"), snap("43", "linear.app")],
                                windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 0, "43 is new — no prev URL to diff")
    }

    func testClosedTabDoesNotEmit() {
        var sm = ChromeNavStateMachine()
        _ = sm.observe(snapshots: [snap("42", "github.com"), snap("43", "linear.app")],
                       windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("42", "github.com")], windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 0, "43 closed — not a nav event")
    }

    func testMultipleTabsNavigatingEmitMultipleEvents() {
        var sm = ChromeNavStateMachine()
        _ = sm.observe(snapshots: [snap("42", "github.com"), snap("43", "linear.app")],
                       windowID: "W1", nowMs: 1000)
        let events = sm.observe(snapshots: [snap("42", "github.io"), snap("43", "linear.io")],
                                windowID: "W1", nowMs: 2000)
        XCTAssertEqual(events.count, 2)
    }
}
