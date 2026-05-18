// Packages/LeafCore/Tests/LeafCoreTests/DetailRangeTests.swift
import XCTest

@testable import LeafCore

final class DetailRangeTests: XCTestCase {

    /// Frozen reference instant: 2026-05-17T14:32:00 UTC (a Sunday).
    /// Calendar is iso8601 with UTC timezone so week boundaries are
    /// deterministic across runners.
    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var now: Date {
        DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026, month: 5, day: 17, hour: 14, minute: 32
        ).date!
    }

    func testTodayStartsAtMidnight() {
        let interval = DetailRange.today.interval(now: now, calendar: calendar)
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: interval.start)
        XCTAssertEqual(startComponents.year, 2026)
        XCTAssertEqual(startComponents.month, 5)
        XCTAssertEqual(startComponents.day, 17)
        XCTAssertEqual(startComponents.hour, 0)
        XCTAssertEqual(startComponents.minute, 0)
        XCTAssertEqual(interval.end, now)
    }

    func testWeekStartsMonday() {
        // iso8601 calendar — Monday is firstWeekday=2; week containing
        // 2026-05-17 (Sunday) starts on 2026-05-11.
        let interval = DetailRange.week.interval(now: now, calendar: calendar)
        let startComponents = calendar.dateComponents([.year, .month, .day], from: interval.start)
        XCTAssertEqual(startComponents.year, 2026)
        XCTAssertEqual(startComponents.month, 5)
        XCTAssertEqual(startComponents.day, 11)
        XCTAssertEqual(interval.end, now)
    }

    func testMonthStartsFirstOfMonth() {
        let interval = DetailRange.month.interval(now: now, calendar: calendar)
        let startComponents = calendar.dateComponents([.year, .month, .day], from: interval.start)
        XCTAssertEqual(startComponents.year, 2026)
        XCTAssertEqual(startComponents.month, 5)
        XCTAssertEqual(startComponents.day, 1)
        XCTAssertEqual(interval.end, now)
    }

    func testDefaultIsWeek() {
        XCTAssertEqual(DetailRange.default, .week)
    }

    func testIdentifiable() {
        XCTAssertEqual(DetailRange.today.id, "today")
        XCTAssertEqual(DetailRange.week.id, "week")
        XCTAssertEqual(DetailRange.month.id, "month")
    }
}
