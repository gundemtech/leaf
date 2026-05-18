import XCTest

@testable import LeafCore

final class GoogleCalendarActivityBreakdownTests: XCTestCase {

    func test_empty_isAllZeros() {
        let empty = GoogleCalendarActivityBreakdown.empty
        XCTAssertEqual(empty.focusBlockCount, 0)
        XCTAssertEqual(empty.focusDurationSeconds, 0)
        XCTAssertEqual(empty.oooBlockCount, 0)
        XCTAssertEqual(empty.workingLocationCount, 0)
        XCTAssertTrue(empty.dailyFocusMinutes.isEmpty)
    }

    func test_equatable_roundtrip() {
        let a = GoogleCalendarActivityBreakdown(
            focusBlockCount: 3,
            focusDurationSeconds: 5_400,
            oooBlockCount: 1,
            workingLocationCount: 2,
            dailyFocusMinutes: [0, 30, 30, 30, 0, 0, 0]
        )
        let aCopy = GoogleCalendarActivityBreakdown(
            focusBlockCount: 3,
            focusDurationSeconds: 5_400,
            oooBlockCount: 1,
            workingLocationCount: 2,
            dailyFocusMinutes: [0, 30, 30, 30, 0, 0, 0]
        )
        let b = GoogleCalendarActivityBreakdown(
            focusBlockCount: 4,
            focusDurationSeconds: 5_400,
            oooBlockCount: 1,
            workingLocationCount: 2,
            dailyFocusMinutes: [0, 30, 30, 30, 0, 0, 0]
        )
        XCTAssertEqual(a, aCopy)
        XCTAssertNotEqual(a, b)
    }

    func test_cardPayload_init_assignsFields() {
        let payload = GoogleCalendarCardPayload(
            focusBlockCount: 5,
            focusDurationSeconds: 9_000,
            oooBlockCount: 0,
            workingLocationCount: 3,
            dailyFocusMinutes: [30, 30, 30, 30, 30, 0, 0]
        )
        XCTAssertEqual(payload.focusBlockCount, 5)
        XCTAssertEqual(payload.focusDurationSeconds, 9_000)
        XCTAssertEqual(payload.oooBlockCount, 0)
        XCTAssertEqual(payload.workingLocationCount, 3)
        XCTAssertEqual(payload.dailyFocusMinutes.count, 7)
    }

    func test_sendable_acrossTaskBoundary() async {
        let breakdown = GoogleCalendarActivityBreakdown.empty
        let echoed = await Task.detached { breakdown }.value
        XCTAssertEqual(echoed, breakdown)
    }
}
