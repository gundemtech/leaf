import XCTest

@testable import LeafCore

final class CalendarAppStateMachineTests: XCTestCase {
    func testFirstObservationEmits() {
        var sm = CalendarAppStateMachine()
        let events = sm.observe(CalendarAppViewObservation(viewMode: .week, visibleDateRangeDays: 7), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "calendar_app_view_changed")
        XCTAssertEqual(events[0].payload["view_mode"], "week")
        XCTAssertEqual(events[0].payload["visible_date_range_days"], "7")
    }

    func testIdempotentEmitsNothing() {
        var sm = CalendarAppStateMachine()
        let obs = CalendarAppViewObservation(viewMode: .week, visibleDateRangeDays: 7)
        _ = sm.observe(obs, nowMs: 1000)
        XCTAssertEqual(sm.observe(obs, nowMs: 2000).count, 0)
    }

    func testViewModeChangeEmits() {
        var sm = CalendarAppStateMachine()
        _ = sm.observe(CalendarAppViewObservation(viewMode: .week, visibleDateRangeDays: 7), nowMs: 1000)
        let events = sm.observe(CalendarAppViewObservation(viewMode: .month, visibleDateRangeDays: 30), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["view_mode"], "month")
        XCTAssertEqual(events[0].payload["visible_date_range_days"], "30")
    }

    func testPayloadHasNoEventTitleOrAttendeeFields() {
        var sm = CalendarAppStateMachine()
        let events = sm.observe(CalendarAppViewObservation(viewMode: .day, visibleDateRangeDays: 1), nowMs: 1000)
        XCTAssertNil(events[0].payload["title"])
        XCTAssertNil(events[0].payload["summary"])
        XCTAssertNil(events[0].payload["attendees"])
        XCTAssertNil(events[0].payload["location"])
        XCTAssertNil(events[0].payload["description"])
    }
}
