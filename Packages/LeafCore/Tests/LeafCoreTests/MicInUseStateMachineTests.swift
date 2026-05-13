import XCTest
@testable import LeafCore

final class MicInUseStateMachineTests: XCTestCase {

    func testFirstObservationReturnsNil() {
        var sm = MicInUseStateMachine()
        XCTAssertNil(sm.observe(false))
    }

    func testFalseToTrueEmitsEntered() {
        var sm = MicInUseStateMachine()
        _ = sm.observe(false)
        XCTAssertEqual(sm.observe(true), .entered)
    }

    func testTrueToFalseEmitsExited() {
        var sm = MicInUseStateMachine()
        _ = sm.observe(true)
        XCTAssertEqual(sm.observe(false), .exited)
    }

    func testRepeatedIdenticalValueNoEmit() {
        var sm = MicInUseStateMachine()
        _ = sm.observe(true)
        XCTAssertNil(sm.observe(true))
        _ = sm.observe(false)
        XCTAssertNil(sm.observe(false))
    }
}
