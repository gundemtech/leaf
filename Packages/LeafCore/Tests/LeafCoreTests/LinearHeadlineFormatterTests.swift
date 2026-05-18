// LinearHeadlineFormatterTests.swift
import XCTest

@testable import LeafCore

final class LinearHeadlineFormatterTests: XCTestCase {
    func test_zeroIssues_pluralized() {
        let b = LinearActivityBreakdown.empty
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertEqual(h.value, "0 issues touched")
        XCTAssertNil(h.trend)
    }

    func test_singularIssue_singular() {
        let b = LinearActivityBreakdown(
            issuesTouched: 1, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: nil, issueCloseStreak: nil
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertEqual(h.value, "1 issue touched")
    }

    func test_multipleIssues_plural() {
        let b = LinearActivityBreakdown(
            issuesTouched: 47, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: nil, issueCloseStreak: nil
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertEqual(h.value, "47 issues touched")
    }

    func test_positiveWowDelta_renderedInTrend() {
        let b = LinearActivityBreakdown(
            issuesTouched: 47, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: 0.12, issueCloseStreak: nil
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertNotNil(h.trend)
        XCTAssertTrue(h.trend!.contains("+12%"), "expected +12% in trend, got \(h.trend!)")
    }

    func test_negativeWowDelta_renderedWithMinusSign() {
        let b = LinearActivityBreakdown(
            issuesTouched: 10, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: -0.25, issueCloseStreak: nil
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("−25%") || h.trend!.contains("-25%"))
    }

    func test_streakAppearsInTrend() {
        let b = LinearActivityBreakdown(
            issuesTouched: 10, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: nil, issueCloseStreak: 4
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertNotNil(h.trend)
        XCTAssertTrue(h.trend!.contains("4-day"))
    }

    func test_oneDayStreak_singular() {
        let b = LinearActivityBreakdown(
            issuesTouched: 5, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: nil, issueCloseStreak: 1
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("1-day"))
    }

    func test_zeroStreak_omittedFromTrend() {
        let b = LinearActivityBreakdown(
            issuesTouched: 5, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: 0.05, issueCloseStreak: 0
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertFalse(h.trend!.contains("day"))
    }

    func test_bothWowAndStreak_combinedWithDot() {
        let b = LinearActivityBreakdown(
            issuesTouched: 47, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: 0.12, issueCloseStreak: 3
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("·"))
    }

    func test_noWowNoStreak_trendIsNil() {
        let b = LinearActivityBreakdown(
            issuesTouched: 5, byProject: [], byStatus: [],
            completionDurationStats: nil, wowDeltaPct: nil, issueCloseStreak: nil
        )
        let h = LinearHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertNil(h.trend)
    }
}
