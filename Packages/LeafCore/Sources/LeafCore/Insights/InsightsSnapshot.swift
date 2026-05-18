import Foundation

/// View-model для popover (и любого другого consumer'а) — агрегированный
/// результат одного refresh-цикла Derived Insights Engine.
///
/// Phase 2.1 — три метрики (timeInApp + sessions + switchRate). Phase 2.2
/// расширен trends-полями (deepWorkStreak / peakHour / wow / activeDaysInRow).
/// Phase 2.3 — `aiRatio`. Trend-поля добавляются с semantic zero defaults
/// в convenience init'е — не ломает existing test callsite'ы.
///
/// Snapshot consider'ится empty если ВСЕ 7 текущих метрик пусты/zero/nil.
/// Partial-empty (есть topApps, нет sessions, нет trends) — `.loaded` с
/// placeholder в соответствующем UI-блоке.
public struct InsightsSnapshot: Sendable, Hashable {
    public let topApps: [AppTimeEntry]
    public let sessions: [FocusSession]
    /// Switches per active hour. `0.0` если active hours == 0.
    public let switchRate: Double
    /// Precomputed: count of sessions с `duration >= deepSessionMinSec`.
    /// Делается на producer-side чтобы UI не таскал threshold.
    public let deepSessionsCount: Int
    /// Phase 2.2 — consecutive days с deep session + cumulative deep time.
    /// `DeepWorkStreak.empty` == семантический "нет streak'а".
    public let deepWorkStreak: DeepWorkStreak
    /// Phase 2.2 — hour-of-day (0..23) наибольшей attention'а в trailing
    /// `peakHourWindowDays`. `nil` = данных меньше `peakHourMinActiveDays`.
    public let peakProductivityHour: Int?
    /// Phase 2.2 — signed fractional change attention time (`+0.12` = +12%).
    /// `nil` = baseline insufficient (prev week empty или `< wowBaselineMinActiveDays`).
    public let weekOverWeekDelta: Double?
    /// Phase 2.2 — consecutive active days ending at today/yesterday.
    /// `0` = сегодня не active и yesterday не active.
    public let activeDaysInRow: Int
    /// Phase 2.3 — per-minute bucket union ratio aiCollab/(ai∪attention).
    /// `0` = либо нет AI events, либо нет ни одной активной минуты в окне.
    public let aiRatio: Double
    /// Phase 2.3 — distinct minutes с AI activity × 60. UI показывает рядом с %.
    public let aiActiveSeconds: TimeInterval
    /// Phase 2.4 — top-N file paths за `period` (recency-ordered, MAX 10).
    /// Содержит уже granularity-mapped paths (router'ом on write — L4 даёт
    /// folder-level, L5 — full path). UI показывает basename + tooltip.
    public let filesTouched: [String]
    /// Phase 4.2 — distinct Linear issue keys touched за `period`.
    public let linearIssuesTouched: Int
    /// Phase 4.2 — top-5 projects by issue count, descending.
    public let linearByProject: [ProjectCountEntry]
    /// Phase 4.2 — top-5 statuses by issue count, descending.
    public let linearByStatus: [StatusCountEntry]
    /// Phase 4.6.A.2 — completion duration distribution для issues, completed
    /// в `period`. `nil` если samples=0 (никто не закрыт за окно).
    public let linearCompletionDurationStats: LatencyStats?
    /// Phase 4.3 — total GitHub events за `period` (commits / PRs / issues / reviews).
    public let githubEventsCount: Int
    /// Phase 4.3 — top-5 repos by event count, descending.
    public let githubByRepo: [RepoCountEntry]
    /// Phase 4.3 — top-5 event_kinds by count, descending.
    public let githubByEventKind: [EventKindCountEntry]
    /// Phase 4.6.A.1 — `gh_pr_merged` cycle time distribution. `nil` если samples=0.
    public let githubPRCycleStats: LatencyStats?
    /// Phase 4.6.A.1 — `gh_pr_review_submitted` review delay distribution. `nil` если samples=0.
    public let githubReviewDelayStats: LatencyStats?
    /// Phase 4.4 — total Slack messages authored за `period` (sum of per-channel counts).
    public let slackMessagesCount: Int
    /// Phase 4.4 — total minutes юзер провёл в huddle'е за `period`, walk'ом
    /// huddle_state_change context events с clipping к границам periodа.
    public let slackHuddleMinutes: Int
    /// Phase 4.4 — top-5 channels by message count, descending. DM channels уже
    /// merged'ы в один "DM" bucket (ADR-010 anonymization).
    public let slackByChannel: [SlackActivityBreakdown.ChannelCountEntry]
    /// Phase 4.6.A.3 — sum реакций на authored messages за `period` (aggregate
    /// numeric). `0` ↔ нет реакций / Slack не подключён / pre-4.6 events. UI
    /// conditional на `> 0` для рендера.
    public let slackReactionsReceived: Int
    /// Phase 4.6.A.3 — distribution длительностей huddle sessions. `nil` ↔
    /// samples=0 (не было пар transitions в окне). Отличает "одна 45m" от
    /// "пять 9m" сессий — current `slackHuddleMinutes` total это растворяет.
    public let slackHuddleSessionStats: LatencyStats?
    /// Phase 4.6.C.2 — самое длинное окно в `period` без events из Linear/
    /// GitHub/Slack. Proxy для "deep async work session" — integration silence,
    /// не macOS-level idle. `nil` ↔ period degenerate ИЛИ impl не поддерживает.
    public let longestUninterruptedWindow: UninterruptedWindow?
    /// Phase 4.6.C.3 — consecutive days с ≥1 closed Linear issue (60-day
    /// lookback, period-independent). `0` ↔ нет closes ни сегодня, ни вчера.
    /// UI рендерит "Streak: 🔥 N days" в tooltip при `>= 3`.
    public let linearIssueCloseStreak: Int
    /// Phase 4.6.C.3 — consecutive days с ≥1 GitHub commit pushed
    /// (60-day lookback, period-independent). `0` ↔ ни сегодня, ни вчера.
    public let githubCommitStreak: Int
    /// Phase 4.6.C.3 — consecutive days с ≥1 Slack huddle joined
    /// (state='in_a_huddle' transition, 60-day lookback, period-independent).
    public let slackHuddleParticipationStreak: Int
    /// Phase 4.6.B — counts моих status transitions за `period`. `nil` ↔ нет
    /// transitions в окне / Linear не подключён.
    public let linearTransitions: LinearTransitionBreakdown?
    /// Phase 4.6.B — soft follow-through ratio (completed / (completed + started
    /// + reopened)). `nil` ↔ `completed == 0` (см. LinearActivityBreakdown doc).
    public let linearCompletionRate: Double?
    /// Phase 4.10.A — chronological per-event feed for the Activity tab. Most
    /// recent first, capped on producer side. Empty ↔ no events in `period`
    /// or insights provider returned default empty (Stub / non-prod build).
    public let recentActivity: [ActivityFeedEntry]
    /// Phase 4.10.A — current cross-provider presence (live state — not period
    /// scoped). Drives the Live Presence widget on Home. `.empty` ↔ no
    /// `presence_state` rows yet (provider not connected / pre-4.7 install).
    public let presenceState: PresenceUISnapshot
    /// Phase 4.10.B — aggregated work sessions for the Activity tab "Sessions"
    /// mode and the Home "Recent sessions" block. Sorted by start desc on the
    /// producer side. Empty ↔ no attention events in `period` or producer not
    /// wired (StubInsights / non-prod build / B-7 not landed yet).
    public let recentSessions: [ActivitySession]
    /// Track 7 P2-collapsed — Xcode build/test breakdown for the snapshot's
    /// reference period. `nil` ↔ snapshot builder did not compute (P2-collapsed
    /// defers builder extension; cards fall back to "Open for details" headline).
    public let xcodeActivity: XcodeActivityBreakdown?
    public let idesActivity: IDEsActivityBreakdown?
    public let browsersActivity: BrowsersActivityBreakdown?
    public let zoomActivity: ZoomActivityBreakdown?
    public let googleCalendarActivity: GoogleCalendarActivityBreakdown?
    /// Phase Track-7 P3 — D3 work state summary (decisions / open questions /
    /// open blockers). `nil` ↔ no Work State data assembled (e.g. snapshot
    /// builder is in private moat and not yet wired, fresh DB with no D3 rows,
    /// or non-prod StubInsights conformer). `WorkStateCardViewModel` collapses
    /// `nil` → `WorkStateSummary.empty` so the Home card always renders
    /// "All clear" rather than disappearing.
    public let workState: WorkStateSummary?
    /// Phase Track-8 P3 — TODAY block metrics (focused minutes / AI ratio /
    /// sessions / context switches / commits + surface pills). Default
    /// `.empty` so existing callsites (tests, previews) keep compiling
    /// without modification; production `InsightsReader.refresh()` writes
    /// the real value via `DerivedInsights.todayMetrics(now:)`.
    public let todayMetrics: TodayMetrics
    /// Phase Track-8 P4 — YOU·NOW dashboard cell state (active /
    /// inMeeting / deepWorkFocus / away). Default `.empty` matches the
    /// `todayMetrics` pattern — no fixture sweep needed across existing
    /// snapshot construction sites. Production
    /// `InsightsReader.refresh()` writes the real value via
    /// `DerivedInsights.youNowState(now:)`.
    public let youNowState: YouNowState
    /// Phase Track-8 P5 — teammates currently working on the same task
    /// as the caller (same Linear issue / same branch / adjacent branch).
    /// Sorted by `SameTaskMatcher` (confidence asc → lastActivityAtMs
    /// desc → displayName asc). Default `[]` so existing call-sites keep
    /// compiling without modification. Production `InsightsReader.refresh()`
    /// writes the real value via
    /// `DerivedInsights.sameTaskTeammates(rule: .hierarchical)` — returns
    /// `[]` until Phase 5.4 wires a DB-backed `TeammatePresenceReader`
    /// against `presence_history`.
    public let sameTaskTeammates: [TeammateMatch]
    /// Phase Track-8 P6 — INBOX dashboard items list (review requests,
    /// comments on my work, mentions, open questions, blockers). Substrate
    /// already sorts by `InboxSeverity.sortRank` asc → `createdAtMs` desc.
    /// Default `[]` so existing call-sites keep compiling without
    /// modification. Production `InsightsReader.refresh()` writes the
    /// real value via `DerivedInsights.inboxItems(filter:query:)`.
    public let inboxItems: [InboxItem]
    /// Phase Track-8 P7 — WHERE STOPPED block snapshot (most recent
    /// stop-point derived from Track-1 D3 `where_stopped_log` plus
    /// commit / ticket / file basename heuristics in
    /// `ProdWhereStoppedDeriver`). Default `nil` so existing call-sites
    /// keep compiling without modification. Production
    /// `InsightsReader.refresh()` writes the real value via
    /// `DerivedInsights.recentWhereStopped(limit: 1).first` — `nil` when
    /// substrate has no row (fresh DB, idle gate not met, or non-prod
    /// `StubInsights` returning `[]`).
    public let whereStopped: WhereStoppedSnapshot?

    public init(
        topApps: [AppTimeEntry],
        sessions: [FocusSession],
        switchRate: Double,
        deepSessionsCount: Int,
        deepWorkStreak: DeepWorkStreak,
        peakProductivityHour: Int?,
        weekOverWeekDelta: Double?,
        activeDaysInRow: Int,
        aiRatio: Double,
        aiActiveSeconds: TimeInterval,
        filesTouched: [String],
        linearIssuesTouched: Int,
        linearByProject: [ProjectCountEntry],
        linearByStatus: [StatusCountEntry],
        linearCompletionDurationStats: LatencyStats?,
        githubEventsCount: Int,
        githubByRepo: [RepoCountEntry],
        githubByEventKind: [EventKindCountEntry],
        githubPRCycleStats: LatencyStats?,
        githubReviewDelayStats: LatencyStats?,
        slackMessagesCount: Int,
        slackHuddleMinutes: Int,
        slackByChannel: [SlackActivityBreakdown.ChannelCountEntry],
        slackReactionsReceived: Int = 0,
        slackHuddleSessionStats: LatencyStats? = nil,
        longestUninterruptedWindow: UninterruptedWindow? = nil,
        linearIssueCloseStreak: Int = 0,
        githubCommitStreak: Int = 0,
        slackHuddleParticipationStreak: Int = 0,
        linearTransitions: LinearTransitionBreakdown? = nil,
        linearCompletionRate: Double? = nil,
        recentActivity: [ActivityFeedEntry] = [],
        presenceState: PresenceUISnapshot = .empty,
        recentSessions: [ActivitySession] = [],
        xcodeActivity: XcodeActivityBreakdown? = nil,
        idesActivity: IDEsActivityBreakdown? = nil,
        browsersActivity: BrowsersActivityBreakdown? = nil,
        zoomActivity: ZoomActivityBreakdown? = nil,
        googleCalendarActivity: GoogleCalendarActivityBreakdown? = nil,
        workState: WorkStateSummary? = nil,
        todayMetrics: TodayMetrics = .empty,
        youNowState: YouNowState = .empty,
        sameTaskTeammates: [TeammateMatch] = [],
        inboxItems: [InboxItem] = [],
        whereStopped: WhereStoppedSnapshot? = nil
    ) {
        self.topApps = topApps
        self.sessions = sessions
        self.switchRate = switchRate
        self.deepSessionsCount = deepSessionsCount
        self.deepWorkStreak = deepWorkStreak
        self.peakProductivityHour = peakProductivityHour
        self.weekOverWeekDelta = weekOverWeekDelta
        self.activeDaysInRow = activeDaysInRow
        self.aiRatio = aiRatio
        self.aiActiveSeconds = aiActiveSeconds
        self.filesTouched = filesTouched
        self.linearIssuesTouched = linearIssuesTouched
        self.linearByProject = linearByProject
        self.linearByStatus = linearByStatus
        self.linearCompletionDurationStats = linearCompletionDurationStats
        self.githubEventsCount = githubEventsCount
        self.githubByRepo = githubByRepo
        self.githubByEventKind = githubByEventKind
        self.githubPRCycleStats = githubPRCycleStats
        self.githubReviewDelayStats = githubReviewDelayStats
        self.slackMessagesCount = slackMessagesCount
        self.slackHuddleMinutes = slackHuddleMinutes
        self.slackByChannel = slackByChannel
        self.slackReactionsReceived = slackReactionsReceived
        self.slackHuddleSessionStats = slackHuddleSessionStats
        self.longestUninterruptedWindow = longestUninterruptedWindow
        self.linearIssueCloseStreak = linearIssueCloseStreak
        self.githubCommitStreak = githubCommitStreak
        self.slackHuddleParticipationStreak = slackHuddleParticipationStreak
        self.linearTransitions = linearTransitions
        self.linearCompletionRate = linearCompletionRate
        self.recentActivity = recentActivity
        self.presenceState = presenceState
        self.recentSessions = recentSessions
        self.xcodeActivity = xcodeActivity
        self.idesActivity = idesActivity
        self.browsersActivity = browsersActivity
        self.zoomActivity = zoomActivity
        self.googleCalendarActivity = googleCalendarActivity
        self.workState = workState
        self.todayMetrics = todayMetrics
        self.youNowState = youNowState
        self.sameTaskTeammates = sameTaskTeammates
        self.inboxItems = inboxItems
        self.whereStopped = whereStopped
    }

    /// Convenience init — рассчитывает `deepSessionsCount` по threshold'у.
    /// Phase 2.2 — trend-поля с default'ами; Phase 2.3 — AI-поля с default'ами;
    /// Phase 2.4 — `filesTouched` с default `[]`. Phase 4.2 — Linear-поля с defaults.
    /// Phase 4.3 — GitHub-поля с defaults. Phase 4.4 — Slack-поля с defaults.
    /// Phase 4.10.A — `recentActivity` с default `[]`.
    /// Existing test/UI callsite'ы не ломаются.
    public init(
        topApps: [AppTimeEntry],
        sessions: [FocusSession],
        switchRate: Double,
        deepSessionMinSec: TimeInterval,
        deepWorkStreak: DeepWorkStreak = .empty,
        peakProductivityHour: Int? = nil,
        weekOverWeekDelta: Double? = nil,
        activeDaysInRow: Int = 0,
        aiRatio: Double = 0,
        aiActiveSeconds: TimeInterval = 0,
        filesTouched: [String] = [],
        linearIssuesTouched: Int = 0,
        linearByProject: [ProjectCountEntry] = [],
        linearByStatus: [StatusCountEntry] = [],
        linearCompletionDurationStats: LatencyStats? = nil,
        githubEventsCount: Int = 0,
        githubByRepo: [RepoCountEntry] = [],
        githubByEventKind: [EventKindCountEntry] = [],
        githubPRCycleStats: LatencyStats? = nil,
        githubReviewDelayStats: LatencyStats? = nil,
        slackMessagesCount: Int = 0,
        slackHuddleMinutes: Int = 0,
        slackByChannel: [SlackActivityBreakdown.ChannelCountEntry] = [],
        slackReactionsReceived: Int = 0,
        slackHuddleSessionStats: LatencyStats? = nil,
        longestUninterruptedWindow: UninterruptedWindow? = nil,
        linearIssueCloseStreak: Int = 0,
        githubCommitStreak: Int = 0,
        slackHuddleParticipationStreak: Int = 0,
        linearTransitions: LinearTransitionBreakdown? = nil,
        linearCompletionRate: Double? = nil,
        recentActivity: [ActivityFeedEntry] = [],
        presenceState: PresenceUISnapshot = .empty,
        recentSessions: [ActivitySession] = [],
        xcodeActivity: XcodeActivityBreakdown? = nil,
        idesActivity: IDEsActivityBreakdown? = nil,
        browsersActivity: BrowsersActivityBreakdown? = nil,
        zoomActivity: ZoomActivityBreakdown? = nil,
        googleCalendarActivity: GoogleCalendarActivityBreakdown? = nil,
        workState: WorkStateSummary? = nil,
        todayMetrics: TodayMetrics = .empty,
        youNowState: YouNowState = .empty,
        sameTaskTeammates: [TeammateMatch] = [],
        inboxItems: [InboxItem] = [],
        whereStopped: WhereStoppedSnapshot? = nil
    ) {
        self.init(
            topApps: topApps,
            sessions: sessions,
            switchRate: switchRate,
            deepSessionsCount: sessions.filter { $0.duration >= deepSessionMinSec }.count,
            deepWorkStreak: deepWorkStreak,
            peakProductivityHour: peakProductivityHour,
            weekOverWeekDelta: weekOverWeekDelta,
            activeDaysInRow: activeDaysInRow,
            aiRatio: aiRatio,
            aiActiveSeconds: aiActiveSeconds,
            filesTouched: filesTouched,
            linearIssuesTouched: linearIssuesTouched,
            linearByProject: linearByProject,
            linearByStatus: linearByStatus,
            linearCompletionDurationStats: linearCompletionDurationStats,
            githubEventsCount: githubEventsCount,
            githubByRepo: githubByRepo,
            githubByEventKind: githubByEventKind,
            githubPRCycleStats: githubPRCycleStats,
            githubReviewDelayStats: githubReviewDelayStats,
            slackMessagesCount: slackMessagesCount,
            slackHuddleMinutes: slackHuddleMinutes,
            slackByChannel: slackByChannel,
            slackReactionsReceived: slackReactionsReceived,
            slackHuddleSessionStats: slackHuddleSessionStats,
            longestUninterruptedWindow: longestUninterruptedWindow,
            linearIssueCloseStreak: linearIssueCloseStreak,
            githubCommitStreak: githubCommitStreak,
            slackHuddleParticipationStreak: slackHuddleParticipationStreak,
            linearTransitions: linearTransitions,
            linearCompletionRate: linearCompletionRate,
            recentActivity: recentActivity,
            presenceState: presenceState,
            recentSessions: recentSessions,
            xcodeActivity: xcodeActivity,
            idesActivity: idesActivity,
            browsersActivity: browsersActivity,
            zoomActivity: zoomActivity,
            googleCalendarActivity: googleCalendarActivity,
            workState: workState,
            todayMetrics: todayMetrics,
            youNowState: youNowState,
            sameTaskTeammates: sameTaskTeammates,
            inboxItems: inboxItems,
            whereStopped: whereStopped
        )
    }

    public var isEmpty: Bool {
        topApps.isEmpty
            && sessions.isEmpty
            && switchRate == 0
            && deepWorkStreak.days == 0
            && peakProductivityHour == nil
            && weekOverWeekDelta == nil
            && activeDaysInRow == 0
            && aiRatio == 0
            && aiActiveSeconds == 0
            && filesTouched.isEmpty
            && linearIssuesTouched == 0
            && githubEventsCount == 0
            && slackMessagesCount == 0
            && slackHuddleMinutes == 0
            && recentActivity.isEmpty
            && presenceState.isEmpty
            && recentSessions.isEmpty
    }

    /// Average session duration. `0` если sessions пуст.
    public var avgSessionDuration: TimeInterval {
        guard !sessions.isEmpty else { return 0 }
        return sessions.reduce(0.0) { $0 + $1.duration } / Double(sessions.count)
    }
}
