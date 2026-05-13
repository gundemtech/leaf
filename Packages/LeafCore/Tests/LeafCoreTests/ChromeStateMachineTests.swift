import XCTest
@testable import LeafCore

final class ChromeStateMachineTests: XCTestCase {
    private let tabA = BrowserTab(title: "X", url: "https://x.com")
    private let tabB = BrowserTab(title: "Y", url: "https://y.com")

    func testFirstObservationEmits() {
        var sm = ChromeStateMachine()
        let events = sm.observe(ChromeObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "chrome_tabs_changed")
    }

    func testIdenticalURLSetEmitsNothing() {
        var sm = ChromeStateMachine()
        _ = sm.observe(ChromeObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 1000)
        XCTAssertEqual(sm.observe(ChromeObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 2000).count, 0)
    }

    func testAddingTabEmits() {
        var sm = ChromeStateMachine()
        _ = sm.observe(ChromeObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 1000)
        let events = sm.observe(ChromeObservation(tabs: [tabA, tabB], activeWindowID: "W"), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
    }

    func testRemovingTabEmits() {
        var sm = ChromeStateMachine()
        _ = sm.observe(ChromeObservation(tabs: [tabA, tabB], activeWindowID: "W"), nowMs: 1000)
        let events = sm.observe(ChromeObservation(tabs: [tabA], activeWindowID: "W"), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
    }
}
