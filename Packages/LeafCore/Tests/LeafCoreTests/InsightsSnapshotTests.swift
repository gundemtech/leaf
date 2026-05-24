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
    // MARK: - Phase 8.4 — youNowState defaulted init

    func test_init_defaultsYouNowStateToEmpty() {
        XCTAssertEqual(emptySnapshot().youNowState, .empty)
    }

    // MARK: - Track-10 T6 — activeTeammates + memberCount defaulted inits

    /// Defaulted `activeTeammates: [TeammateSnapshot] = []` matches the
    /// `sameTaskTeammates` / `sinceLastActiveItems` pattern — existing test
    /// fixtures keep compiling without an explicit override.
    func testSnapshotDefaultsActiveTeammatesEmpty() {
        XCTAssertEqual(emptySnapshot().activeTeammates, [])
    }

    func testSnapshotCarriesActiveTeammates() {
        let snap = TeammateSnapshot(
            memberID: "m-1",
            displayName: "Anton",
            linearID: "LEAF-204",
            branch: "feature/foo",
            repo: "leaf",
            currentApp: "Xcode",
            lastActivityAtMs: 1_700_000_000_000
        )
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            activeTeammates: [snap]
        )
        XCTAssertEqual(snapshot.activeTeammates, [snap])
    }

    /// Defaulted `memberCount: Int = 1` is the solo Mac default — matches the
    /// Phase IV.B `readTeamMembers` rewire's fallback (nil active workspace or
    /// membership read failure → 1). Track-10 T6 HomeView Zone 3 reads this for
    /// the solo-vs-team gate.
    func testSnapshotDefaultsMemberCountToOne() {
        XCTAssertEqual(emptySnapshot().memberCount, 1)
    }

    func testSnapshotCarriesMemberCount() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            memberCount: 3
        )
        XCTAssertEqual(snapshot.memberCount, 3)
    }

    // MARK: - Track-10 T7 — currentSession defaulted init

    /// Defaulted `currentSession: CurrentTaskSession? = nil` matches the T2
    /// gitDelta / currentTaskIdentity pattern — existing fixture / test
    /// callsites stay unmodified. 13th iteration of defaulted-init blast-radius.
    func testSnapshotDefaultsCurrentSessionToNil() {
        XCTAssertNil(emptySnapshot().currentSession)
    }

    func testSnapshotCarriesCurrentSession() {
        let task = TaskIdentity(linearID: "GUN-50", branch: "feature/x")
        let session = CurrentTaskSession(
            taskIdentity: task, sessionStartMs: 100,
            focusedMinSoFar: 5, openFiles: ["A.swift"])
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            currentSession: session
        )
        XCTAssertEqual(snapshot.currentSession, session)
    }
    // MARK: - Phase Track-8 P6 — INBOX

    func testSnapshotDefaultsInboxItemsEmpty() {
        XCTAssertEqual(emptySnapshot().inboxItems, [])
    }

    func testSnapshotRoundTripsInboxItems() {
        let item = InboxItem(
            id: "x",
            kind: .reviewRequest,
            severity: .warn,
            title: "PR review",
            sourceMeta: "GitHub · 1h ago",
            sourceURL: URL(string: "https://github.com/x/y/pull/1"),
            aggregatedCount: 1,
            createdAtMs: 0
        )
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            inboxItems: [item]
        )
        XCTAssertEqual(snapshot.inboxItems, [item])
    }

    // MARK: - Phase Track-8 P7 — WHERE STOPPED

    func testSnapshotDefaultsWhereStoppedToNil() {
        XCTAssertNil(emptySnapshot().whereStopped)
    }

    func testSnapshotRoundTripsWhereStopped() {
        let row = WhereStoppedSnapshot(
            id: 1,
            generatedAtMs: 1_700_000_000_000,
            anchorEventId: 42,
            excerpt: "Track-7 P5 polish · WorkStateCard.swift",
            wipSignals: ["commitWip", "midEdit"]
        )
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            whereStopped: row
        )
        XCTAssertEqual(snapshot.whereStopped, row)
    }

    // MARK: - Phase Track-9 T9 — WEEKLY METRICS (Analytics surface)

    func testSnapshotDefaultsWeeklyMetricsToEmpty() {
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500
        )
        XCTAssertEqual(snapshot.weeklyMetrics, .empty)
    }

    // MARK: - Track-10 T8 — standupRecap defaulted init (14th iteration)

    /// Defaulted `standupRecap: StandupSnapshot? = nil` matches the T7
    /// `currentSession` precedent. Existing fixture/test callsites stay
    /// unmodified — `emptySnapshot()` returns nil for the new field without
    /// any signature change.
    func testSnapshotDefaultsStandupRecapToNil() {
        XCTAssertNil(emptySnapshot().standupRecap)
    }

    func testSnapshotCarriesStandupRecap() {
        let recap = StandupRecap(
            yesterdayCommitsCount: 3,
            yesterdayClosedLinearKeys: ["GUN-204"],
            yesterdayReviewedPRsCount: 2,
            todayContinuing: nil,
            waitingItems: [],
            openBlockers: []
        )
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            standupRecap: StandupSnapshot(recap: recap, eod: nil)
        )
        XCTAssertEqual(snapshot.standupRecap?.recap, recap)
        XCTAssertNil(snapshot.standupRecap?.eod)
    }

    func testSnapshotRoundTripsWeeklyMetrics() {
        let custom = WeeklyMetrics(
            dailySeries: Array(repeating: DailyMetric.empty, count: 7),
            peakHour: 14,
            wowDelta: 0.12,
            commitStreak: 3,
            issueCloseStreak: 2,
            huddleStreak: 1,
            focusSessionStreak: 4,
            heavyPulseStreak: 0
        )
        let snapshot = InsightsSnapshot(
            topApps: [],
            sessions: [],
            switchRate: 0,
            deepSessionMinSec: 1500,
            weeklyMetrics: custom
        )
        XCTAssertEqual(snapshot.weeklyMetrics, custom)
        XCTAssertEqual(snapshot.weeklyMetrics.peakHour, 14)
        XCTAssertEqual(snapshot.weeklyMetrics.commitStreak, 3)
    }
}
