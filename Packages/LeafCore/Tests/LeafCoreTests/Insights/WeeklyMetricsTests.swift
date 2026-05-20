import XCTest

@testable import LeafCore

// Track-9 T4 — Sentinel-injection regression tests are intentionally absent here.
// T4 ships a deriver-only phase: `weeklyMetrics(now:)` reads existing aggregate
// counts (commits / status transitions / huddle starts / focus sessions / heavy
// pulse buckets) and emits numeric metrics + opaque day-start timestamps. No
// body fields, file paths, message text, or other forbidden surfaces flow
// through the deriver. See T4 spec §5.4 (`docs/superpowers/specs/2026-05-20-
// track-9-T4-weekly-metrics-deriver.md`) for the explicit exemption rationale.
final class WeeklyMetricsTests: XCTestCase {
    func testWeeklyMetricsEquatableRoundTrip() {
        let day = DailyMetric(
            dayStartMs: 1_700_000_000_000,
            focusedMin: 42, sessionsCount: 3, commitsCount: 5, aiRatio: 0.6)
        let series = Array(repeating: day, count: 7)
        let m = WeeklyMetrics(
            dailySeries: series,
            peakHour: 14, wowDelta: 0.15,
            commitStreak: 5, issueCloseStreak: 2, huddleStreak: 1,
            focusSessionStreak: 4, heavyPulseStreak: 3)
        XCTAssertEqual(m, m)
        XCTAssertEqual(m.dailySeries.count, 7)
        XCTAssertEqual(m.peakHour, 14)
        XCTAssertEqual(m.wowDelta, 0.15)
        XCTAssertEqual(m.commitStreak, 5)
        XCTAssertEqual(m.issueCloseStreak, 2)
        XCTAssertEqual(m.huddleStreak, 1)
        XCTAssertEqual(m.focusSessionStreak, 4)
        XCTAssertEqual(m.heavyPulseStreak, 3)
    }

    func testWeeklyMetricsEmptyShape() {
        let empty = WeeklyMetrics.empty
        XCTAssertEqual(empty.dailySeries.count, 7)
        XCTAssertTrue(empty.dailySeries.allSatisfy { $0 == DailyMetric.empty })
        XCTAssertNil(empty.peakHour)
        XCTAssertNil(empty.wowDelta)
        XCTAssertEqual(empty.commitStreak, 0)
        XCTAssertEqual(empty.issueCloseStreak, 0)
        XCTAssertEqual(empty.huddleStreak, 0)
        XCTAssertEqual(empty.focusSessionStreak, 0)
        XCTAssertEqual(empty.heavyPulseStreak, 0)
    }

    func testDailyMetricEquatableRoundTrip() {
        let d = DailyMetric(
            dayStartMs: 1_700_000_000_000,
            focusedMin: 60, sessionsCount: 2, commitsCount: 3, aiRatio: 0.4)
        XCTAssertEqual(d, d)
        XCTAssertEqual(d.dayStartMs, 1_700_000_000_000)
        XCTAssertEqual(d.focusedMin, 60)
        XCTAssertEqual(d.sessionsCount, 2)
        XCTAssertEqual(d.commitsCount, 3)
        XCTAssertEqual(d.aiRatio, 0.4, accuracy: 1e-9)
    }

    func testDailyMetricEmptyShape() {
        let e = DailyMetric.empty
        XCTAssertEqual(e.dayStartMs, 0)
        XCTAssertEqual(e.focusedMin, 0)
        XCTAssertEqual(e.sessionsCount, 0)
        XCTAssertEqual(e.commitsCount, 0)
        XCTAssertEqual(e.aiRatio, 0.0)
    }
}
