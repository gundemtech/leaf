// GitHubHeadlineFormatterTests.swift
import XCTest

@testable import LeafCore

final class GitHubHeadlineFormatterTests: XCTestCase {
    func test_zeroEvents_pluralized() {
        let h = GitHubHeadlineFormatter.headline(breakdown: .empty, range: .week)
        XCTAssertEqual(h.value, "0 events")
        XCTAssertNil(h.trend)
    }

    func test_singleEvent_singular() {
        let b = GitHubActivityBreakdown(
            eventsCount: 1, byRepo: [], byEventKind: [],
            prCycleStats: nil, reviewDelayStats: nil, wowDeltaPct: nil, commitStreak: nil
        )
        XCTAssertEqual(GitHubHeadlineFormatter.headline(breakdown: b, range: .week).value, "1 event")
    }

    func test_multipleEvents_plural() {
        let b = GitHubActivityBreakdown(
            eventsCount: 23, byRepo: [], byEventKind: [],
            prCycleStats: nil, reviewDelayStats: nil, wowDeltaPct: nil, commitStreak: nil
        )
        XCTAssertEqual(GitHubHeadlineFormatter.headline(breakdown: b, range: .week).value, "23 events")
    }

    func test_positiveWowAndCommitStreak() {
        let b = GitHubActivityBreakdown(
            eventsCount: 23, byRepo: [], byEventKind: [],
            prCycleStats: nil, reviewDelayStats: nil, wowDeltaPct: 0.05, commitStreak: 4
        )
        let h = GitHubHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertNotNil(h.trend)
        XCTAssertTrue(h.trend!.contains("+5%"))
        XCTAssertTrue(h.trend!.contains("4-day commit streak"))
        XCTAssertTrue(h.trend!.contains("·"))
    }

    func test_negativeWow() {
        let b = GitHubActivityBreakdown(
            eventsCount: 10, byRepo: [], byEventKind: [],
            prCycleStats: nil, reviewDelayStats: nil, wowDeltaPct: -0.3, commitStreak: nil
        )
        let h = GitHubHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("−30%") || h.trend!.contains("-30%"))
    }

    func test_oneDayCommitStreak_singular() {
        let b = GitHubActivityBreakdown(
            eventsCount: 5, byRepo: [], byEventKind: [],
            prCycleStats: nil, reviewDelayStats: nil, wowDeltaPct: nil, commitStreak: 1
        )
        let h = GitHubHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertTrue(h.trend!.contains("1-day commit streak"))
    }

    func test_zeroStreak_omitted() {
        let b = GitHubActivityBreakdown(
            eventsCount: 5, byRepo: [], byEventKind: [],
            prCycleStats: nil, reviewDelayStats: nil, wowDeltaPct: 0.1, commitStreak: 0
        )
        let h = GitHubHeadlineFormatter.headline(breakdown: b, range: .week)
        XCTAssertFalse(h.trend!.contains("commit streak"))
    }

    func test_noWowNoStreak_trendNil() {
        let b = GitHubActivityBreakdown(
            eventsCount: 5, byRepo: [], byEventKind: [],
            prCycleStats: nil, reviewDelayStats: nil, wowDeltaPct: nil, commitStreak: nil
        )
        XCTAssertNil(GitHubHeadlineFormatter.headline(breakdown: b, range: .week).trend)
    }

    func test_eventCount_acceptsLargeNumbers() {
        let b = GitHubActivityBreakdown(
            eventsCount: 1234, byRepo: [], byEventKind: [],
            prCycleStats: nil, reviewDelayStats: nil, wowDeltaPct: nil, commitStreak: nil
        )
        XCTAssertEqual(GitHubHeadlineFormatter.headline(breakdown: b, range: .week).value, "1234 events")
    }
}
