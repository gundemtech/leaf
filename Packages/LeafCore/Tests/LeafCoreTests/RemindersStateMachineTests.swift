import XCTest
@testable import LeafCore

final class RemindersStateMachineTests: XCTestCase {
    func testFirstObservationDoesNotEmit() {
        var sm = RemindersStateMachine()
        let events = sm.observe(RemindersCompletionObservation(listName: "Inbox", completedCountDelta: 5), nowMs: 1000)
        XCTAssertEqual(events.count, 0)
    }

    func testPositiveDeltaEmitsAfterBootstrap() {
        var sm = RemindersStateMachine()
        _ = sm.observe(RemindersCompletionObservation(listName: "Inbox", completedCountDelta: 0), nowMs: 1000)
        let events = sm.observe(RemindersCompletionObservation(listName: "Inbox", completedCountDelta: 3), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "reminder_completed")
        XCTAssertEqual(events[0].payload["list_name"], "Inbox")
        XCTAssertEqual(events[0].payload["completed_count_delta"], "3")
    }

    func testZeroOrNegativeDeltaEmitsNothing() {
        var sm = RemindersStateMachine()
        _ = sm.observe(RemindersCompletionObservation(listName: nil, completedCountDelta: 0), nowMs: 1000)
        XCTAssertEqual(sm.observe(RemindersCompletionObservation(listName: nil, completedCountDelta: 0), nowMs: 2000).count, 0)
        XCTAssertEqual(sm.observe(RemindersCompletionObservation(listName: nil, completedCountDelta: -2), nowMs: 3000).count, 0)
    }

    func testPayloadHasNoReminderTitleField() {
        var sm = RemindersStateMachine()
        _ = sm.observe(RemindersCompletionObservation(listName: "L", completedCountDelta: 0), nowMs: 1000)
        let events = sm.observe(RemindersCompletionObservation(listName: "L", completedCountDelta: 1), nowMs: 2000)
        XCTAssertNil(events[0].payload["body"])
        XCTAssertNil(events[0].payload["title"])
        XCTAssertNil(events[0].payload["reminder_title"])
        XCTAssertNil(events[0].payload["notes"])
    }
}
