import XCTest

@testable import LeafCore

final class VPNStateMachineTests: XCTestCase {

    func testConnectedToDisconnectedEmits() {
        var sm = VPNStateMachine()
        _ = sm.observe(.connected)
        XCTAssertEqual(sm.observe(.disconnected), .disconnected)
    }

    func testDisconnectedToConnectedEmits() {
        var sm = VPNStateMachine()
        _ = sm.observe(.disconnected)
        XCTAssertEqual(sm.observe(.connected), .connected)
    }

    func testIntermediateStatesNoEmit() {
        var sm = VPNStateMachine()
        XCTAssertNil(sm.observe(.connecting))
        XCTAssertNil(sm.observe(.disconnecting))
        XCTAssertNil(sm.observe(.reasserting))
    }

    func testQuickFlapSuppressionVisible() {
        var sm = VPNStateMachine()
        _ = sm.observe(.connected)
        // Reasserting during a stable .connected session — no transition.
        XCTAssertNil(sm.observe(.reasserting))
        XCTAssertNil(sm.observe(.connected))
        XCTAssertEqual(sm.observe(.disconnected), .disconnected)
    }

    func testInvalidMapsToDisconnected() {
        var sm = VPNStateMachine()
        _ = sm.observe(.connected)
        XCTAssertEqual(sm.observe(.invalid), .disconnected)
    }
}
