import XCTest

@testable import LeafCore

final class ClipboardCounterStateMachineTests: XCTestCase {

    func testFirstObservationReturnsNil() {
        var sm = ClipboardCounterStateMachine()
        XCTAssertNil(sm.observe(42), "first obs primes lastCount без emit")
    }

    func testPositiveDeltaEmits() {
        var sm = ClipboardCounterStateMachine()
        _ = sm.observe(10)
        XCTAssertEqual(sm.observe(13), 3)
    }

    func testZeroDeltaReturnsNil() {
        var sm = ClipboardCounterStateMachine()
        _ = sm.observe(10)
        XCTAssertNil(sm.observe(10))
    }

    func testNegativeDeltaReturnsNil() {
        var sm = ClipboardCounterStateMachine()
        _ = sm.observe(100)
        // Counter wrap or reset: negative delta → no emit, но lastCount обновляется.
        XCTAssertNil(sm.observe(5))
        // Subsequent positive delta from new baseline emits.
        XCTAssertEqual(sm.observe(8), 3)
    }
}
