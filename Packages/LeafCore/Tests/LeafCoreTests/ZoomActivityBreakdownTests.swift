import XCTest

@testable import LeafCore

final class ZoomActivityBreakdownTests: XCTestCase {

    func test_empty_isAllZeros() {
        let empty = ZoomActivityBreakdown.empty
        XCTAssertEqual(empty.meetingCount, 0)
        XCTAssertEqual(empty.totalDurationSeconds, 0)
        XCTAssertEqual(empty.calendarLinkedCount, 0)
        XCTAssertEqual(empty.adHocCount, 0)
        XCTAssertEqual(empty.longestMeetingSeconds, 0)
        XCTAssertTrue(empty.dailyMinutes.isEmpty)
    }

    func test_equatable_roundtrip() {
        let a = ZoomActivityBreakdown(
            meetingCount: 4,
            totalDurationSeconds: 3_600,
            calendarLinkedCount: 3,
            adHocCount: 1,
            longestMeetingSeconds: 1_800,
            dailyMinutes: [0, 30, 0, 0, 30, 0, 0]
        )
        let aCopy = ZoomActivityBreakdown(
            meetingCount: 4,
            totalDurationSeconds: 3_600,
            calendarLinkedCount: 3,
            adHocCount: 1,
            longestMeetingSeconds: 1_800,
            dailyMinutes: [0, 30, 0, 0, 30, 0, 0]
        )
        let b = ZoomActivityBreakdown(
            meetingCount: 4,
            totalDurationSeconds: 3_600,
            calendarLinkedCount: 3,
            adHocCount: 1,
            longestMeetingSeconds: 2_400,
            dailyMinutes: [0, 30, 0, 0, 30, 0, 0]
        )
        XCTAssertEqual(a, aCopy)
        XCTAssertNotEqual(a, b)
    }

    func test_cardPayload_init_assignsFields() {
        let payload = ZoomCardPayload(
            meetingCount: 6,
            totalDurationSeconds: 5_400,
            calendarLinkedCount: 5,
            adHocCount: 1,
            dailyMinutes: [0, 0, 30, 30, 0, 30, 0]
        )
        XCTAssertEqual(payload.meetingCount, 6)
        XCTAssertEqual(payload.totalDurationSeconds, 5_400)
        XCTAssertEqual(payload.calendarLinkedCount, 5)
        XCTAssertEqual(payload.adHocCount, 1)
        XCTAssertEqual(payload.dailyMinutes.count, 7)
    }

    func test_sendable_acrossTaskBoundary() async {
        let breakdown = ZoomActivityBreakdown.empty
        let echoed = await Task.detached { breakdown }.value
        XCTAssertEqual(echoed, breakdown)
    }
}
