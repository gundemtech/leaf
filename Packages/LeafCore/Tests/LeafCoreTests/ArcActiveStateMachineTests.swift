// Packages/LeafCore/Tests/LeafCoreTests/ArcActiveStateMachineTests.swift
import XCTest
@testable import LeafCore

final class ArcActiveStateMachineTests: XCTestCase {
    func testColdTickNoEmit() {
        var sm = ArcActiveStateMachine()
        let e = sm.observe(currentTabKey: "i1", currentURL: "github.com", title: "",
                           windowID: "W1", nowMs: 1000)
        XCTAssertEqual(e.count, 0)
    }

    func testTabSwitchInSameWindowEmits() {
        var sm = ArcActiveStateMachine()
        _ = sm.observe(currentTabKey: "i1", currentURL: "github.com", title: "",
                       windowID: "W1", nowMs: 1000)
        let e = sm.observe(currentTabKey: "i2", currentURL: "linear.app", title: "",
                           windowID: "W1", nowMs: 2000)
        XCTAssertEqual(e.count, 1)
        guard case .tabActivated(_, let prevKey, let currKey, _, _, _, _) = e[0] else {
            return XCTFail()
        }
        XCTAssertEqual(prevKey, "i1")
        XCTAssertEqual(currKey, "i2")
    }

    func testWindowSwitchEmits() {
        var sm = ArcActiveStateMachine()
        _ = sm.observe(currentTabKey: "i1", currentURL: "github.com", title: "",
                       windowID: "W1", nowMs: 1000)
        let e = sm.observe(currentTabKey: "i1", currentURL: "linear.app", title: "",
                           windowID: "W2", nowMs: 2000)
        XCTAssertEqual(e.count, 1, "different window — emit even if tabKey identical")
    }

    func testNoWindowIDNoEmit() {
        var sm = ArcActiveStateMachine()
        _ = sm.observe(currentTabKey: "i1", currentURL: "github.com", title: "",
                       windowID: "W1", nowMs: 1000)
        let e = sm.observe(currentTabKey: "i2", currentURL: "linear.app", title: "",
                           windowID: nil, nowMs: 2000)
        XCTAssertEqual(e.count, 0, "no window — Arc closed mid-tick")
    }
}
