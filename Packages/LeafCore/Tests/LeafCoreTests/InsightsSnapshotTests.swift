import XCTest
@testable import LeafCore

/// Phase 2.5 — закрепляем семантику `InsightsSnapshot.isEmpty`. Это
/// load-bearing property: `InsightsReader` решает по нему `.loaded` vs
/// `.empty` в UI state machine. Любое новое поле snapshot'а должно быть
/// учтено в `isEmpty` — иначе ненулевое поле "проглотится" глобальным
/// "Collecting…" placeholder'ом.
final class InsightsSnapshotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func emptySnapshot() -> InsightsSnapshot {
        InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500
        )
    }

    func testEmptyWhenAllFieldsZero() {
        XCTAssertTrue(emptySnapshot().isEmpty)
    }

    func testNotEmptyWhenTopAppsPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [
                AppTimeEntry(bundleID: "com.apple.dt.Xcode", duration: 600, firstSeen: now, lastSeen: now)
            ],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenSessionsPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [
                FocusSession(bundleID: "com.apple.dt.Xcode", start: now, end: now.addingTimeInterval(900))
            ],
            switchRate: 0,
            deepSessionMinSec: 1500
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenAIRatioPositive() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            aiRatio: 0.05,
            aiActiveSeconds: 300
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenStreakDaysPositive() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            deepWorkStreak: DeepWorkStreak(days: 1, totalSeconds: 1500)
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenFilesTouchedPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            filesTouched: ["~/Desktop/LeafControl/Leaf/LeafApp.swift"]
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenPeakHourPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            peakProductivityHour: 14
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenWeekOverWeekDeltaPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            weekOverWeekDelta: -0.10
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenActiveDaysInRowPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            activeDaysInRow: 3
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    func testNotEmptyWhenSwitchRatePositive() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 4.2,
            deepSessionMinSec: 1500
        )
        XCTAssertFalse(snapshot.isEmpty)
    }

    // MARK: - Phase 4.2 Linear

    func testEmptyWhenLinearZero() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 0,
            linearByProject: [],
            linearByStatus: []
        )
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.linearIssuesTouched, 0)
    }

    func testNotEmptyWhenLinearIssuesPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 3,
            linearByProject: [ProjectCountEntry(project: "Leaf", count: 3)],
            linearByStatus: [StatusCountEntry(status: "In Progress", count: 3)]
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.linearIssuesTouched, 3)
        XCTAssertEqual(snapshot.linearByProject.first?.project, "Leaf")
    }

    // MARK: - Phase 4.4 Slack

    func testEmptyWhenSlackZero() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackMessagesCount: 0,
            slackHuddleMinutes: 0,
            slackByChannel: []
        )
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.slackMessagesCount, 0)
        XCTAssertEqual(snapshot.slackHuddleMinutes, 0)
    }

    func testNotEmptyWhenSlackMessagesPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackMessagesCount: 7,
            slackByChannel: [SlackActivityBreakdown.ChannelCountEntry(channelName: "engineering", count: 7)]
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.slackMessagesCount, 7)
        XCTAssertEqual(snapshot.slackByChannel.first?.channelName, "engineering")
    }

    func testNotEmptyWhenSlackHuddleMinutesPresent() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackHuddleMinutes: 30
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.slackHuddleMinutes, 30)
    }

    // MARK: - Phase 4.6.A.1 GitHub latency

    func testGithubLatencyStatsRoundTripWhenPresent() {
        let cycle = LatencyStats(medianSeconds: 1800, avgSeconds: 2000, maxSeconds: 3600, sampleCount: 3)
        let delay = LatencyStats(medianSeconds: 900, avgSeconds: 900, maxSeconds: 1200, sampleCount: 2)
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            githubEventsCount: 5,
            githubByRepo: [RepoCountEntry(repo: "octocat/leaf", count: 5)],
            githubByEventKind: [EventKindCountEntry(eventKind: "gh_pr_merged", count: 3)],
            githubPRCycleStats: cycle,
            githubReviewDelayStats: delay
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.githubPRCycleStats?.medianSeconds, 1800)
        XCTAssertEqual(snapshot.githubReviewDelayStats?.sampleCount, 2)
    }

    func testGithubLatencyStatsNilByDefault() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            githubEventsCount: 0
        )
        XCTAssertNil(snapshot.githubPRCycleStats)
        XCTAssertNil(snapshot.githubReviewDelayStats)
        XCTAssertTrue(snapshot.isEmpty, "no events + nil latency → empty")
    }

    func testLatencyStatsFromSamplesEvenCount() {
        // sorted: 100, 200, 300, 400 → median = (200+300)/2 = 250, avg=250, max=400.
        let stats = try? XCTUnwrap(LatencyStats.from(samples: [400, 100, 300, 200]))
        XCTAssertEqual(stats?.sampleCount, 4)
        XCTAssertEqual(stats?.medianSeconds, 250)
        XCTAssertEqual(stats?.avgSeconds, 250)
        XCTAssertEqual(stats?.maxSeconds, 400)
    }

    func testLatencyStatsFromEmptySamplesReturnsNil() {
        XCTAssertNil(LatencyStats.from(samples: []))
    }

    // MARK: - Phase 4.6.A.2 Linear completion duration

    func testLinearCompletionStatsRoundTripWhenPresent() {
        let dur = LatencyStats(medianSeconds: 7200, avgSeconds: 9000, maxSeconds: 14400, sampleCount: 3)
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 3,
            linearByProject: [ProjectCountEntry(project: "Leaf", count: 3)],
            linearByStatus: [StatusCountEntry(status: "Done", count: 3)],
            linearCompletionDurationStats: dur
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.linearCompletionDurationStats?.medianSeconds, 7200)
        XCTAssertEqual(snapshot.linearCompletionDurationStats?.sampleCount, 3)
        XCTAssertEqual(snapshot.linearCompletionDurationStats?.maxSeconds, 14400)
    }

    func testLinearCompletionStatsNilByDefault() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 0
        )
        XCTAssertNil(snapshot.linearCompletionDurationStats)
        XCTAssertTrue(snapshot.isEmpty, "no issues + nil completion stats → empty")
    }

    // MARK: - Phase 4.6.A.3 Slack reactions + huddle session stats

    func testSlackReactionsAndHuddleSessionStatsRoundTripWhenPresent() {
        let huddleStats = LatencyStats(medianSeconds: 1500, avgSeconds: 1500, maxSeconds: 2400, sampleCount: 3)
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackMessagesCount: 5,
            slackHuddleMinutes: 75,
            slackByChannel: [SlackActivityBreakdown.ChannelCountEntry(channelName: "engineering", count: 5)],
            slackReactionsReceived: 8,
            slackHuddleSessionStats: huddleStats
        )
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertEqual(snapshot.slackReactionsReceived, 8)
        XCTAssertEqual(snapshot.slackHuddleSessionStats?.sampleCount, 3)
        XCTAssertEqual(snapshot.slackHuddleSessionStats?.medianSeconds, 1500)
        XCTAssertEqual(snapshot.slackHuddleSessionStats?.maxSeconds, 2400)
    }

    func testSlackReactionsAndHuddleSessionStatsDefaultsBackwardCompat() {
        // Existing test/UI callsites без новых параметров не ломаются.
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            slackMessagesCount: 3
        )
        XCTAssertEqual(snapshot.slackReactionsReceived, 0, "default 0 для backward compat")
        XCTAssertNil(snapshot.slackHuddleSessionStats, "default nil")
        XCTAssertFalse(snapshot.isEmpty, "messages > 0 → не empty")
    }

    // MARK: - Phase 4.6.C.1 — wowDeltaPct в breakdown structs

    func testLinearBreakdownWowDeltaPctDefaultNil() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: []
        )
        XCTAssertNil(bd.wowDeltaPct, "default nil — backwards compat")
    }

    func testLinearBreakdownWowDeltaPctExplicit() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: [],
            wowDeltaPct: 0.12
        )
        XCTAssertEqual(bd.wowDeltaPct, 0.12)
    }

    func testGithubBreakdownWowDeltaPctDefaultNil() {
        let bd = GitHubActivityBreakdown(
            eventsCount: 5,
            byRepo: [],
            byEventKind: []
        )
        XCTAssertNil(bd.wowDeltaPct)
    }

    func testGithubBreakdownWowDeltaPctExplicit() {
        let bd = GitHubActivityBreakdown(
            eventsCount: 5,
            byRepo: [],
            byEventKind: [],
            wowDeltaPct: -0.05
        )
        XCTAssertEqual(bd.wowDeltaPct, -0.05, "negative WoW сохраняется")
    }

    func testSlackBreakdownWowDeltaPctDefaultNil() {
        let bd = SlackActivityBreakdown(
            messagesCount: 10,
            huddleMinutes: 0,
            byChannel: []
        )
        XCTAssertNil(bd.wowDeltaPct)
    }

    func testSlackBreakdownWowDeltaPctExplicit() {
        let bd = SlackActivityBreakdown(
            messagesCount: 10,
            huddleMinutes: 0,
            byChannel: [],
            wowDeltaPct: 0.0
        )
        XCTAssertEqual(bd.wowDeltaPct, 0.0, "zero WoW (без change) — legitimate value, не nil")
    }

    // MARK: - Phase 4.6.C.2 — longestUninterruptedWindow

    func testSnapshotLongestUninterruptedWindowDefaultNil() {
        XCTAssertNil(emptySnapshot().longestUninterruptedWindow,
            "convenience init без аргумента → default nil (backwards compat)")
    }

    func testSnapshotLongestUninterruptedWindowExplicit() {
        let win = UninterruptedWindow(
            start: now,
            end: now.addingTimeInterval(9000),
            durationSeconds: 9000,
            sourcesActiveInPeriod: ["github", "slack"]
        )
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            longestUninterruptedWindow: win
        )
        XCTAssertEqual(snapshot.longestUninterruptedWindow?.durationSeconds, 9000)
        XCTAssertEqual(snapshot.longestUninterruptedWindow?.sourcesActiveInPeriod,
                       ["github", "slack"])
    }

    /// Default extension impl возвращает nil — StubInsights не override'ит,
    /// поэтому iOS-future / CI и тесты с stub'ом работают без ошибок.
    func testStubInsightsLongestUninterruptedWindowDefaultsToNil() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-insights-window-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let db = try Database.openForWrite(at: dbURL, config: .weakDefaults, encryption: nil)
        let stub = StubInsights(database: db)
        let win = try stub.longestUninterruptedWindow(
            period: DateInterval(start: now, end: now.addingTimeInterval(3600))
        )
        XCTAssertNil(win, "default extension impl — nil")
    }

    // MARK: - Phase 4.6.C.3 — per-provider streaks в breakdown structs

    func testLinearBreakdownIssueCloseStreakDefaultNil() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: []
        )
        XCTAssertNil(bd.issueCloseStreak, "default nil — backwards compat")
    }

    func testLinearBreakdownIssueCloseStreakExplicit() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: [],
            issueCloseStreak: 5
        )
        XCTAssertEqual(bd.issueCloseStreak, 5)
    }

    func testGithubBreakdownCommitStreakDefaultNil() {
        let bd = GitHubActivityBreakdown(
            eventsCount: 5,
            byRepo: [],
            byEventKind: []
        )
        XCTAssertNil(bd.commitStreak)
    }

    func testGithubBreakdownCommitStreakExplicit() {
        let bd = GitHubActivityBreakdown(
            eventsCount: 5,
            byRepo: [],
            byEventKind: [],
            commitStreak: 12
        )
        XCTAssertEqual(bd.commitStreak, 12, "long streak (12 days) сохраняется")
    }

    func testSlackBreakdownHuddleParticipationStreakDefaultNil() {
        let bd = SlackActivityBreakdown(
            messagesCount: 10,
            huddleMinutes: 0,
            byChannel: []
        )
        XCTAssertNil(bd.huddleParticipationStreak)
    }

    func testSlackBreakdownHuddleParticipationStreakExplicit() {
        let bd = SlackActivityBreakdown(
            messagesCount: 10,
            huddleMinutes: 0,
            byChannel: [],
            huddleParticipationStreak: 1
        )
        XCTAssertEqual(bd.huddleParticipationStreak, 1,
            "single-day streak=1 — legitimate value (не nil), edge между \"never\" и \"started today\"")
    }

    // MARK: - Phase 4.6.B — Linear status transitions

    func testLinearBreakdownTransitionsDefaultNil() {
        let bd = LinearActivityBreakdown(
            issuesTouched: 3,
            byProject: [],
            byStatus: []
        )
        XCTAssertNil(bd.transitions, "default nil — backwards compat для existing init callsite'ов")
        XCTAssertNil(bd.completionRate, "default nil — same convention")
    }

    func testLinearBreakdownTransitionsExplicit() {
        let transitions = LinearTransitionBreakdown(started: 2, completed: 3, canceled: 1, reopened: 1)
        let bd = LinearActivityBreakdown(
            issuesTouched: 5,
            byProject: [],
            byStatus: [],
            transitions: transitions,
            completionRate: 0.5
        )
        XCTAssertEqual(bd.transitions?.started, 2)
        XCTAssertEqual(bd.transitions?.completed, 3)
        XCTAssertEqual(bd.transitions?.canceled, 1)
        XCTAssertEqual(bd.transitions?.reopened, 1)
        XCTAssertEqual(bd.transitions?.total, 7, "sum может exceed unique transition count для completed→canceled overlap")
        XCTAssertEqual(bd.completionRate, 0.5)
    }

    func testLinearTransitionBreakdownCodableRoundTrip() throws {
        let original = LinearTransitionBreakdown(started: 5, completed: 3, canceled: 1, reopened: 2)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LinearTransitionBreakdown.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.total, 11)
    }

    func testLinearTransitionBreakdownEmpty() {
        let empty = LinearTransitionBreakdown.empty
        XCTAssertEqual(empty.started, 0)
        XCTAssertEqual(empty.completed, 0)
        XCTAssertEqual(empty.canceled, 0)
        XCTAssertEqual(empty.reopened, 0)
        XCTAssertEqual(empty.total, 0)
    }

    func testSnapshotLinearTransitionsRoundTrip() {
        let transitions = LinearTransitionBreakdown(started: 1, completed: 2, canceled: 0, reopened: 0)
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 3,
            linearTransitions: transitions,
            linearCompletionRate: 2.0 / 3.0
        )
        XCTAssertEqual(snapshot.linearTransitions?.started, 1)
        XCTAssertEqual(snapshot.linearTransitions?.completed, 2)
        XCTAssertEqual(snapshot.linearTransitions?.total, 3)
        XCTAssertEqual(snapshot.linearCompletionRate, 2.0 / 3.0)
    }

    func testSnapshotLinearTransitionsDefaultsBackwardCompat() {
        // Existing callsite'ы без новых параметров продолжают работать.
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            linearIssuesTouched: 3
        )
        XCTAssertNil(snapshot.linearTransitions, "default nil")
        XCTAssertNil(snapshot.linearCompletionRate, "default nil")
    }

    func testStubInsightsLinearTransitionsAndCompletionRateDefaults() throws {
        // StubInsights наследует default extension impl → .empty / nil
        // (для CI / iOS-future / тест-сценариев без LeafCorePrivate).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-stub-tx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let _ = try Database.openForWrite(at: tmp, config: .weakDefaults)
        let reader = try Database.openForRead(at: tmp, config: .weakDefaults)
        let stub = StubInsights(database: reader)
        let now = Date()
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let transitions = try stub.linearTransitions(period: period)
        XCTAssertEqual(transitions, .empty, "default extension → .empty")
        let rate = try stub.linearCompletionRate(period: period)
        XCTAssertNil(rate, "default extension → nil")
    }

    // MARK: - Track 7 P2-collapsed — 5 new surface breakdown defaults on StubInsights

    private func makeStubInsights(label: String) throws -> StubInsights {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-stub-\(label)-\(UUID().uuidString).sqlite")
        let _ = try Database.openForWrite(at: tmp, config: .weakDefaults)
        let reader = try Database.openForRead(at: tmp, config: .weakDefaults)
        return StubInsights(database: reader)
    }

    func testStubInsightsXcodeActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "xcode")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.xcodeActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    func testStubInsightsIDEsActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "ides")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.idesActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    func testStubInsightsBrowsersActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "browsers")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.browsersActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    func testStubInsightsZoomActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "zoom")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.zoomActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    func testStubInsightsGoogleCalendarActivityBreakdownDefaultsToEmpty() throws {
        let stub = try makeStubInsights(label: "gcal")
        let period = DateInterval(start: now.addingTimeInterval(-3600), end: now)
        let breakdown = try stub.googleCalendarActivityBreakdown(period: period)
        XCTAssertEqual(breakdown, .empty, "StubInsights inherits .empty default")
    }

    // MARK: - Track 7 P2-collapsed — 5 new InsightsSnapshot optional surface fields

    /// Convenience init без новых параметров → все 5 surface полей nil.
    /// Существующие callsite'ы (DerivedInsightsFactory / ProdInsightsSnapshotBuilder /
    /// MCP handlers / view-models) не трогают новые поля — back-compat guaranteed
    /// nil defaults.
    func test_track7P2Defaults_areNil() {
        let snapshot = emptySnapshot()
        XCTAssertNil(snapshot.xcodeActivity)
        XCTAssertNil(snapshot.idesActivity)
        XCTAssertNil(snapshot.browsersActivity)
        XCTAssertNil(snapshot.zoomActivity)
        XCTAssertNil(snapshot.googleCalendarActivity)
    }

    /// Full memberwise init принимает все 5 опциональных surface полей —
    /// passing `.empty` round-trips through the stored properties.
    func test_track7P2_explicitValuesRoundTrip() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            xcodeActivity: .empty,
            idesActivity: .empty,
            browsersActivity: .empty,
            zoomActivity: .empty,
            googleCalendarActivity: .empty
        )
        XCTAssertEqual(snapshot.xcodeActivity, .empty)
        XCTAssertEqual(snapshot.idesActivity, .empty)
        XCTAssertEqual(snapshot.browsersActivity, .empty)
        XCTAssertEqual(snapshot.zoomActivity, .empty)
        XCTAssertEqual(snapshot.googleCalendarActivity, .empty)
        XCTAssertTrue(snapshot.isEmpty,
            ".empty surface breakdowns don't flip isEmpty — Track 7 P2 fields excluded from isEmpty check (nil = not computed, not zero data)")
    }
}
