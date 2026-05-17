import XCTest

@testable import LeafCore

final class ArcStateMachineTests: XCTestCase {
    private let tabA = BrowserTab(title: "X", url: "https://x.com")
    private let tabB = BrowserTab(title: "Y", url: "https://y.com")

    func testFirstObservationEmits() {
        var sm = ArcStateMachine()
        let events = sm.observe(ArcObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "arc_tabs_changed")
    }

    func testIdenticalURLSetEmitsNothing() {
        var sm = ArcStateMachine()
        _ = sm.observe(ArcObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 1000)
        XCTAssertEqual(sm.observe(ArcObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 2000).count, 0)
    }

    func testAddingTabEmits() {
        var sm = ArcStateMachine()
        _ = sm.observe(ArcObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 1000)
        let events = sm.observe(ArcObservation(tabs: [tabA, tabB], activeWindowID: "W"), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
    }

    func testEmptyTabSetEmitsOnFirst() {
        var sm = ArcStateMachine()
        let events = sm.observe(ArcObservation(tabs: [], activeWindowID: nil), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
    }
}
