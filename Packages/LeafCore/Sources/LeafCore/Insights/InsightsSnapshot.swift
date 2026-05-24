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
    /// Phase Track-7 P3 — D3 work state summary (decisions / open questions /
    /// open blockers). `nil` ↔ no Work State data assembled (e.g. snapshot
    /// builder is in private moat and not yet wired, fresh DB with no D3 rows,
    /// or non-prod StubInsights conformer). `WorkStateCardViewModel` collapses
    /// "All clear" rather than disappearing.
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
    /// Phase Track-9 T9 — Analytics surface 7-day weekly metrics
    /// (focus minutes / AI ratio / sessions / commits per day +
    /// peak hour + WoW delta + 5 streaks). Default `.empty` mirrors
    /// P3 todayMetrics / P4 youNowState pattern: substrate ships
    /// `WeeklyMetrics.empty` first-class, callsites read
    /// `weeklyMetrics == .empty` Equatable check for AnalyticsContent
    /// empty-state branching. Production `InsightsReader.refresh()`
    /// writes the real value via `DerivedInsights.weeklyMetrics(now:)`
    /// (T4 substrate; `StubInsights` default returns `.empty` for
    /// non-prod / iOS-future paths).
    public let weeklyMetrics: WeeklyMetrics
    /// Track-10 T2 — in-process git delta info for the caller's current workspace
    /// (commits ahead/behind merge base + uncommitted count + parsed remote ref).
    /// Default `nil` ↔ workspace path unknown / not a git repo / subprocess failure.
    /// Powers the RESUME hero block's WIP signal line + "Diff with main" CTA.
    public let gitDelta: GitDeltaSnapshot?
    /// Track-10 T2 — current `TaskIdentity` resolved from the most recent attention
    /// event (linearID + branch + repo + workspacePath + linearWorkspaceSlug). Default
    /// `nil` ↔ no attention event in the freshness window. Powers the RESUME hero
    /// task line + Resume/Linear CTAs.
    public let currentTaskIdentity: TaskIdentity?
    /// Track-10 T5 — per-event SINCE YOU WERE LAST ACTIVE timeline rows composed
    /// from `DerivedInsights.recentActivityFeed(since:limit:)`. Empty default keeps
    /// fixture / test callsites passing without override.
    public let sinceLastActiveItems: [SinceLastActiveItem]
    /// Track-10 T6 — teammates last-seen within the freshness window (15 min default),
    /// populated by `TeammatePresenceReader.recentTeammateSnapshots(maxAge:now:)`. Empty
    /// default keeps existing fixture/test callsites compiling without override.
    /// Production `InsightsReader.refresh()` writes the real value once Phase 5.4 wires
    /// `DBTeammatePresenceReader` against `presence_history`; before then the stub
    /// returns `[]` and the TEAM·N block renders its "Team presence sync coming
    /// soon." empty CTA.
    public let activeTeammates: [TeammateSnapshot]
    /// Track-10 T6 — `OrgService.activeMemberCount()` (= 1 when no org row, otherwise
    /// `team_members.removed_at_ms IS NULL` count). Drives the Home Zone-3 solo-vs-team
    /// gate (`memberCount > 1` → 2-col ViewThatFits with NEEDS YOU + TEAM·N; else
    /// NEEDS YOU full-width). Defaults to `1` so existing callsites keep solo-user
    /// behavior without populating.
    public let memberCount: Int
    /// Track-10 T7 — bundled task-session lens consumed by the Home YOU'RE ON
    /// block (LEAF-ID + branch + commits ahead + session start clock + per-task
    /// focused minutes + recent open files). Composed once per
    /// `InsightsReader.refresh()` via `DerivedInsights.currentTaskSession()`.
    /// `nil` ↔ no current task identifiable (Terminal-only work, no IDE foreground
    /// in attention history) → YOU'RE ON block renders empty state.
    public let currentSession: CurrentTaskSession?
    /// Track-10 T8 — bundled value type powering the Home Zone-5 RECAP + EOD
    /// standup helper. Composed once per `InsightsReader.refresh()` via
    /// `StandupComposer.compose(...)`. `nil` ↔ composer received all-zero
    /// inputs (cold DB / non-prod stub) → both blocks render empty-state
    /// path. 14th iteration of defaulted-init blast-radius; tail position
    /// preserves T2..T7 callsite back-compat.
    public let standupRecap: StandupSnapshot?

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
        presenceState: PresenceUISnapshot = .empty,
        recentSessions: [ActivitySession] = [],
        todayMetrics: TodayMetrics = .empty,
        youNowState: YouNowState = .empty,
        inboxItems: [InboxItem] = [],
        whereStopped: WhereStoppedSnapshot? = nil,
        weeklyMetrics: WeeklyMetrics = .empty,
        gitDelta: GitDeltaSnapshot? = nil,
        currentTaskIdentity: TaskIdentity? = nil,
        sinceLastActiveItems: [SinceLastActiveItem] = [],
        activeTeammates: [TeammateSnapshot] = [],
        memberCount: Int = 1,
        currentSession: CurrentTaskSession? = nil,
        standupRecap: StandupSnapshot? = nil
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
        self.presenceState = presenceState
        self.recentSessions = recentSessions
        self.todayMetrics = todayMetrics
        self.youNowState = youNowState
        self.inboxItems = inboxItems
        self.whereStopped = whereStopped
        self.weeklyMetrics = weeklyMetrics
        self.gitDelta = gitDelta
        self.currentTaskIdentity = currentTaskIdentity
        self.sinceLastActiveItems = sinceLastActiveItems
        self.activeTeammates = activeTeammates
        self.memberCount = memberCount
        self.currentSession = currentSession
        self.standupRecap = standupRecap
    }

    /// Convenience init — рассчитывает `deepSessionsCount` по threshold'у.
    /// Phase 2.2 — trend-поля с default'ами; Phase 2.3 — AI-поля с default'ами;
    /// Phase 2.4 — `filesTouched` с default `[]`. Phase 4.2 — Linear-поля с defaults.
    /// Phase 4.3 — GitHub-поля с defaults. Phase 4.4 — Slack-поля с defaults.
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
        presenceState: PresenceUISnapshot = .empty,
        recentSessions: [ActivitySession] = [],
        todayMetrics: TodayMetrics = .empty,
        youNowState: YouNowState = .empty,
        inboxItems: [InboxItem] = [],
        whereStopped: WhereStoppedSnapshot? = nil,
        weeklyMetrics: WeeklyMetrics = .empty,
        gitDelta: GitDeltaSnapshot? = nil,
        currentTaskIdentity: TaskIdentity? = nil,
        sinceLastActiveItems: [SinceLastActiveItem] = [],
        activeTeammates: [TeammateSnapshot] = [],
        memberCount: Int = 1,
        currentSession: CurrentTaskSession? = nil,
        standupRecap: StandupSnapshot? = nil
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
            presenceState: presenceState,
            recentSessions: recentSessions,
            todayMetrics: todayMetrics,
            youNowState: youNowState,
            inboxItems: inboxItems,
            whereStopped: whereStopped,
            weeklyMetrics: weeklyMetrics,
            gitDelta: gitDelta,
            currentTaskIdentity: currentTaskIdentity,
            sinceLastActiveItems: sinceLastActiveItems,
            activeTeammates: activeTeammates,
            memberCount: memberCount,
            currentSession: currentSession,
            standupRecap: standupRecap
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
            && presenceState.isEmpty
            && recentSessions.isEmpty
    }

    /// Average session duration. `0` если sessions пуст.
    public var avgSessionDuration: TimeInterval {
        guard !sessions.isEmpty else { return 0 }
        return sessions.reduce(0.0) { $0 + $1.duration } / Double(sessions.count)
    }
}
