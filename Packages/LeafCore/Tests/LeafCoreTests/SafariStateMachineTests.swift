import XCTest
@testable import LeafCore

final class SafariStateMachineTests: XCTestCase {
    private let tabA = BrowserTab(title: "GitHub", url: "https://github.com")
    private let tabB = BrowserTab(title: "Linear", url: "https://linear.app")
    private let tabC = BrowserTab(title: "Anthropic", url: "https://anthropic.com")

    func testFirstObservationEmits() {
        var sm = SafariStateMachine()
        let events = sm.observe(SafariObservation(tabs: [tabA, tabB], activeWindowID: "W1"), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "safari_tabs_changed")
        XCTAssertEqual(events[0].payload["active_window_id"], "W1")
        XCTAssertNotNil(events[0].payload["tabs"])
    }

    func testIdenticalURLSetEmitsNothing() {
        var sm = SafariStateMachine()
        _ = sm.observe(SafariObservation(tabs: [tabA, tabB], activeWindowID: "W1"), nowMs: 1000)
        XCTAssertEqual(sm.observe(SafariObservation(tabs: [tabA, tabB], activeWindowID: "W1"), nowMs: 2000).count, 0)
    }

    func testTabOrderingAloneDoesNotEmit() {
        var sm = SafariStateMachine()
        _ = sm.observe(SafariObservation(tabs: [tabA, tabB], activeWindowID: "W1"), nowMs: 1000)
        XCTAssertEqual(sm.observe(SafariObservation(tabs: [tabB, tabA], activeWindowID: "W1"), nowMs: 2000).count, 0)
    }

    func testAddingTabEmits() {
        var sm = SafariStateMachine()
        _ = sm.observe(SafariObservation(tabs: [tabA], activeWindowID: "W1"), nowMs: 1000)
        let events = sm.observe(SafariObservation(tabs: [tabA, tabC], activeWindowID: "W1"), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
    }

    func testRemovingTabEmits() {
        var sm = SafariStateMachine()
        _ = sm.observe(SafariObservation(tabs: [tabA, tabB, tabC], activeWindowID: "W1"), nowMs: 1000)
        let events = sm.observe(SafariObservation(tabs: [tabA, tabB], activeWindowID: "W1"), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
    }

    func testTabsPayloadIsJSON() throws {
        var sm = SafariStateMachine()
        let events = sm.observe(SafariObservation(tabs: [tabA, tabB], activeWindowID: nil), nowMs: 1000)
        let json = try XCTUnwrap(events[0].payload["tabs"])
        let decoded = try JSONDecoder().decode([BrowserTab].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(Set(decoded.map { $0.url }), [tabA.url, tabB.url])
    }
}
