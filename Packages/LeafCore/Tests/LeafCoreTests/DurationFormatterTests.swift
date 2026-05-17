import XCTest

@testable import LeafCore

final class DurationFormatterTests: XCTestCase {
    func testZeroSeconds() {
        XCTAssertEqual(formatDuration(0), "0s")
    }

    func testSubMinute() {
        XCTAssertEqual(formatDuration(1), "1s")
        XCTAssertEqual(formatDuration(30), "30s")
        XCTAssertEqual(formatDuration(59), "59s")
    }

    func testMinuteBoundary() {
        XCTAssertEqual(formatDuration(60), "1m")
        XCTAssertEqual(formatDuration(59.5), "1m", "Округление вверх в минуту")
    }

    func testMinutesOnly() {
        XCTAssertEqual(formatDuration(120), "2m")
        XCTAssertEqual(formatDuration(1_800), "30m")
        XCTAssertEqual(formatDuration(3_599), "59m")
    }

    func testHourBoundary() {
        XCTAssertEqual(formatDuration(3_600), "1h")
    }

    func testHoursWithMinutes() {
        XCTAssertEqual(formatDuration(3_661), "1h 1m")
        XCTAssertEqual(formatDuration(7_320), "2h 2m")
        XCTAssertEqual(formatDuration(10_200), "2h 50m")
    }

    func testHoursExact() {
        XCTAssertEqual(formatDuration(7_200), "2h")
        XCTAssertEqual(formatDuration(86_400), "24h")
    }
}
