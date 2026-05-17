import XCTest

@testable import LeafCore

final class MeetingStateMachineTests: XCTestCase {

    /// #1 — first observation never emits a transition (bootstrap).
    func testFirstObservationReturnsNil() {
        var sm = MeetingStateMachine()
        XCTAssertNil(sm.observe(MeetingObservation(isInMeeting: true), nowMs: 1_000))
    }

    /// #2 — repeated identical observation never emits.
    func testRepeatedIdenticalObservationReturnsNil() {
        var sm = MeetingStateMachine()
        _ = sm.observe(MeetingObservation(isInMeeting: false), nowMs: 1_000)
        XCTAssertNil(sm.observe(MeetingObservation(isInMeeting: false), nowMs: 2_000))
        XCTAssertNil(sm.observe(MeetingObservation(isInMeeting: false), nowMs: 3_000))
    }

    /// #3 — false → true emits `.entered`.
    func testFalseToTrueEmitsEntered() {
        var sm = MeetingStateMachine()
        _ = sm.observe(MeetingObservation(isInMeeting: false), nowMs: 1_000)
        XCTAssertEqual(sm.observe(MeetingObservation(isInMeeting: true), nowMs: 2_000), .entered)
    }

    /// #4 — true → false emits `.exited`.
    func testTrueToFalseEmitsExited() {
        var sm = MeetingStateMachine()
        _ = sm.observe(MeetingObservation(isInMeeting: true), nowMs: 1_000)
        XCTAssertEqual(sm.observe(MeetingObservation(isInMeeting: false), nowMs: 2_000), .exited)
    }

    /// #5 — flap sequence: false → true → false → true emits .entered, .exited, .entered.
    func testFlapSequenceEmitsAllTransitions() {
        var sm = MeetingStateMachine()
        _ = sm.observe(MeetingObservation(isInMeeting: false), nowMs: 1_000)
        XCTAssertEqual(sm.observe(MeetingObservation(isInMeeting: true), nowMs: 2_000), .entered)
        XCTAssertEqual(sm.observe(MeetingObservation(isInMeeting: false), nowMs: 3_000), .exited)
        XCTAssertEqual(sm.observe(MeetingObservation(isInMeeting: true), nowMs: 4_000), .entered)
    }
}
