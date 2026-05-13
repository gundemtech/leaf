import XCTest
@testable import LeafCore

final class FocusStateMachineTests: XCTestCase {

    /// #1 — first observation never emits a transition (bootstrap).
    func testFirstObservationReturnsNil() {
        var sm = FocusStateMachine()
        XCTAssertNil(sm.observe(FocusObservation(isFocused: true), nowMs: 1_000))
    }

    /// #2 — repeated identical observation never emits.
    func testRepeatedIdenticalObservationReturnsNil() {
        var sm = FocusStateMachine()
        _ = sm.observe(FocusObservation(isFocused: false), nowMs: 1_000)
        XCTAssertNil(sm.observe(FocusObservation(isFocused: false), nowMs: 2_000))
        XCTAssertNil(sm.observe(FocusObservation(isFocused: false), nowMs: 3_000))
    }

    /// #3 — false → true emits `.enabled`.
    func testFalseToTrueEmitsEnabled() {
        var sm = FocusStateMachine()
        _ = sm.observe(FocusObservation(isFocused: false), nowMs: 1_000)
        XCTAssertEqual(sm.observe(FocusObservation(isFocused: true), nowMs: 2_000), .enabled)
    }

    /// #4 — true → false emits `.disabled`.
    func testTrueToFalseEmitsDisabled() {
        var sm = FocusStateMachine()
        _ = sm.observe(FocusObservation(isFocused: true), nowMs: 1_000)
        XCTAssertEqual(sm.observe(FocusObservation(isFocused: false), nowMs: 2_000), .disabled)
    }

    /// #5 — flap sequence emits all transitions.
    func testFlapSequenceEmitsAllTransitions() {
        var sm = FocusStateMachine()
        _ = sm.observe(FocusObservation(isFocused: false), nowMs: 1_000)
        XCTAssertEqual(sm.observe(FocusObservation(isFocused: true), nowMs: 2_000), .enabled)
        XCTAssertEqual(sm.observe(FocusObservation(isFocused: false), nowMs: 3_000), .disabled)
        XCTAssertEqual(sm.observe(FocusObservation(isFocused: true), nowMs: 4_000), .enabled)
    }
}
