import XCTest

@testable import LeafCore

final class NotesStateMachineTests: XCTestCase {
    func testFirstObservationEmits() {
        var sm = NotesStateMachine()
        let events = sm.observe(NotesObservation(activeNoteTitle: "Meeting prep"), nowMs: 1000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["event_kind"], "notes_active_title_changed")
        XCTAssertEqual(events[0].payload["note_title"], "Meeting prep")
    }

    func testIdempotentEmitsNothing() {
        var sm = NotesStateMachine()
        let obs = NotesObservation(activeNoteTitle: "Meeting prep")
        _ = sm.observe(obs, nowMs: 1000)
        XCTAssertEqual(sm.observe(obs, nowMs: 2000).count, 0)
    }

    func testTitleChangeEmits() {
        var sm = NotesStateMachine()
        _ = sm.observe(NotesObservation(activeNoteTitle: "A"), nowMs: 1000)
        let events = sm.observe(NotesObservation(activeNoteTitle: "B"), nowMs: 2000)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].payload["note_title"], "B")
    }

    func testPayloadHasNoBodyField() {
        var sm = NotesStateMachine()
        let events = sm.observe(NotesObservation(activeNoteTitle: "X"), nowMs: 1000)
        XCTAssertNil(events[0].payload["body"])
        XCTAssertNil(events[0].payload["plaintext"])
        XCTAssertNil(events[0].payload["content"])
    }
}
