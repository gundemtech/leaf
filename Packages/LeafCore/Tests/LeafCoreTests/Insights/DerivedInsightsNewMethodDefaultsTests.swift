import XCTest

@testable import LeafCore

final class DerivedInsightsNewMethodDefaultsTests: XCTestCase {
    func testDefaultsViaMinimalConformer() throws {
        let insights: any DerivedInsights = MinimalConformer()
        XCTAssertNil(try insights.currentTaskIdentity())
        XCTAssertTrue(try insights.sameTaskTeammates(rule: .hierarchical).isEmpty)
        XCTAssertTrue(try insights.inboxItems(filter: .all, query: nil).isEmpty)
        XCTAssertEqual(try insights.todayMetrics(now: Date()), .empty)
        let state = try insights.youNowState(now: Date())
        guard case .away(let a) = state else { return XCTFail("expected .away default") }
        XCTAssertEqual(a.reason, .idle)
        XCTAssertEqual(a.idleSec, 0)
    }
}

/// Minimal conformer used to verify default extension implementations.
private struct MinimalConformer: DerivedInsights {
    func timeInApp(period: DateInterval) throws -> [AppTimeEntry] { [] }
    func focusSessions(period: DateInterval) throws -> [FocusSession] { [] }
    func contextSwitchRate(period: DateInterval) throws -> Double { 0 }
    func deepWorkStreak() throws -> DeepWorkStreak { DeepWorkStreak(days: 0, totalSeconds: 0) }
    func peakProductivityHour() throws -> Int? { nil }
    func filesTouched(period: DateInterval) throws -> [String] { [] }
    func aiRatio(period: DateInterval) throws -> Double { 0 }
    func aiActivityBreakdown(period: DateInterval) throws -> AIActivityBreakdown { .empty }
    func linearActivity(period: DateInterval) throws -> LinearActivityBreakdown { .empty }
    func githubActivity(period: DateInterval) throws -> GitHubActivityBreakdown { .empty }
    func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval { 0 }
    func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double { 0 }
    func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry] { [] }
    func weekOverWeekDelta() throws -> Double? { nil }
    func activeDaysInRow() throws -> Int { 0 }
    func lastActivity(bundleID: String?) throws -> ActivitySnapshot? { nil }
}
