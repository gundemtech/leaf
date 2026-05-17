import XCTest

@testable import LeafCore

final class DisplayStateMachineTests: XCTestCase {

    func testAddNewDisplayEmitsConnected() {
        var sm = DisplayStateMachine()
        XCTAssertEqual(
            sm.observe(DisplayChange(displayId: 1, kind: .connected)),
            .connected(1)
        )
    }

    func testRemoveKnownDisplayEmitsDisconnected() {
        var sm = DisplayStateMachine()
        _ = sm.observe(DisplayChange(displayId: 1, kind: .connected))
        XCTAssertEqual(
            sm.observe(DisplayChange(displayId: 1, kind: .disconnected)),
            .disconnected(1)
        )
    }

    func testSameIdAddedTwiceSecondNoEmit() {
        var sm = DisplayStateMachine()
        _ = sm.observe(DisplayChange(displayId: 1, kind: .connected))
        XCTAssertNil(sm.observe(DisplayChange(displayId: 1, kind: .connected)))
    }

    func testMultiDisplaySequence() {
        var sm = DisplayStateMachine()
        XCTAssertEqual(sm.observe(DisplayChange(displayId: 1, kind: .connected)), .connected(1))
        XCTAssertEqual(sm.observe(DisplayChange(displayId: 2, kind: .connected)), .connected(2))
        XCTAssertEqual(sm.observe(DisplayChange(displayId: 1, kind: .disconnected)), .disconnected(1))
        // Display 2 still active; re-connecting display 1 emits again.
        XCTAssertEqual(sm.observe(DisplayChange(displayId: 1, kind: .connected)), .connected(1))
    }

    func testRemoveUnknownDisplayNoEmit() {
        var sm = DisplayStateMachine()
        // Display 42 never registered → disconnected event must no-op.
        XCTAssertNil(sm.observe(DisplayChange(displayId: 42, kind: .disconnected)))
    }
}
