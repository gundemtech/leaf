import XCTest

@testable import LeafCore

/// A minimal conformer that satisfies only the methods that have NO default
/// extension implementation. Everything else (including the new Track-7 P3
/// Work State methods) should fall through to the default extensions, proving
/// their `[]` defaults don't throw.
private struct MinimalConformer: DerivedInsights {
    // Attention / time — no defaults, required
    func timeInApp(period: DateInterval) throws -> [AppTimeEntry] { [] }
    func focusSessions(period: DateInterval) throws -> [FocusSession] { [] }
    func contextSwitchRate(period: DateInterval) throws -> Double { 0 }
    func deepWorkStreak() throws -> DeepWorkStreak { throw LeafError.notImplemented }
    func peakProductivityHour() throws -> Int? { nil }

    // Content — no default
    func filesTouched(period: DateInterval) throws -> [String] { [] }

    // AI collaboration — no defaults
    func aiRatio(period: DateInterval) throws -> Double { 0 }
    func aiActivityBreakdown(period: DateInterval) throws -> AIActivityBreakdown { .empty }

    // External integrations — no defaults (slack has default)
    func linearActivity(period: DateInterval) throws -> LinearActivityBreakdown { .empty }
    func githubActivity(period: DateInterval) throws -> GitHubActivityBreakdown { .empty }

    // Team — no defaults
    func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval { 0 }
    func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double { 0 }
    func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry] { [] }

    // Trends — no defaults
    func weekOverWeekDelta() throws -> Double? { nil }
    func activeDaysInRow() throws -> Int { 0 }

    // Activity lookup — no default
    func lastActivity(bundleID: String?) throws -> ActivitySnapshot? { nil }
}

final class DerivedInsightsWorkStateDefaultsTests: XCTestCase {
    private let day: DateInterval = {
        let now = Date()
        return DateInterval(start: now.addingTimeInterval(-86400), end: now)
    }()

    func testRecentDecisions_defaultEmpty() throws {
        let insights: any DerivedInsights = MinimalConformer()
        let decisions = try insights.recentDecisions(period: day, limit: 30)
        XCTAssertEqual(decisions, [])
    }

    func testOpenQuestions_defaultEmpty() throws {
        let insights: any DerivedInsights = MinimalConformer()
        let questions = try insights.openQuestions(period: day)
        XCTAssertEqual(questions, [])
    }

    func testOpenBlockers_defaultEmpty() throws {
        let insights: any DerivedInsights = MinimalConformer()
        let blockers = try insights.openBlockers()
        XCTAssertEqual(blockers, [])
    }

    func testRecentWhereStopped_defaultEmpty() throws {
        let insights: any DerivedInsights = MinimalConformer()
        let snapshots = try insights.recentWhereStopped(limit: 20)
        XCTAssertEqual(snapshots, [])
    }
}
