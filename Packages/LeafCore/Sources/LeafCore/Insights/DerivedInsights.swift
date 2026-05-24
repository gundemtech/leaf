import Foundation

/// 16 функций Derived Insights Engine (см. architecture.md).
/// Phase 1.1 — сигнатуры + StubInsights что throws .notImplemented.
/// Phase 1.3 — ProdInsights с реальными SQL (в LeafCorePrivate, gitignored).
///
/// Callsite (Agent/App/MCP) выбирает provider компиляцией:
/// ```swift
/// import LeafCore
/// #if LEAF_PROD
/// import LeafCorePrivate
/// let insights: any DerivedInsights = ProdInsights(database: db)
/// #else
/// let insights: any DerivedInsights = StubInsights(database: db)
/// #endif
/// ```
public protocol DerivedInsights: Sendable {
    // Attention / time
    func timeInApp(period: DateInterval) throws -> [AppTimeEntry]
    func focusSessions(period: DateInterval) throws -> [FocusSession]
    func contextSwitchRate(period: DateInterval) throws -> Double
    func deepWorkStreak() throws -> DeepWorkStreak
    func peakProductivityHour() throws -> Int?

    // Content
    func filesTouched(period: DateInterval) throws -> [String]

    // AI collaboration
    func aiRatio(period: DateInterval) throws -> Double
    /// Phase 2.3 — детальный AI-collaboration breakdown для MCP / popover.
    /// `aiRatio` делегирует в `aiActivityBreakdown(period:).ratio`.
    func aiActivityBreakdown(period: DateInterval) throws -> AIActivityBreakdown

    // External integrations (Phase 4.2+ Layer B)
    /// Phase 4.2 — Linear issue activity для periodа.
    /// Source filter: events с `signal_type='action'` AND `payload_json.source='linear'`.
    /// Returns issuesTouched (distinct issue_key count) + breakdown by project/status.
    /// Linear не подключён → .empty (не throws — opt-in feature, no-data ≠ error).
    func linearActivity(period: DateInterval) throws -> LinearActivityBreakdown

    /// Phase 4.3 — GitHub events activity для periodа.
    /// Source filter: events с `signal_type='action'` AND `payload_json.source='github'`.
    /// Returns eventsCount + breakdown by repo/event_kind. GitHub не подключён → .empty.
    func githubActivity(period: DateInterval) throws -> GitHubActivityBreakdown

    /// Phase 4.4 — Slack activity для periodа.
    /// Action events с `payload_json.source='slack' AND event_kind='slack_message_authored_aggregate'`
    /// дают `messagesCount` (sum of `count` field) + `byChannel` (top-5).
    /// Context events с `event_kind='slack_huddle_state_change'` walk'ом дают `huddleMinutes`.
    /// Slack не подключён → .empty (default ext) — opt-in feature, no-data ≠ error.
    func slackActivity(period: DateInterval) throws -> SlackActivityBreakdown

    // Team (Phase 2+)
    func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval
    func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double
    func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry]

    // Trends
    func weekOverWeekDelta() throws -> Double?
    func activeDaysInRow() throws -> Int

    /// Phase 4.6.C.2 — самое длинное окно в `period` без events из Layer B
    /// integrations (Linear/GitHub/Slack). Proxy для "deep async work session" —
    /// время непрерывной работы без notification-interruption из tracked
    /// интеграций. Period bounds — anchors: gap может начинаться в `period.start`
    /// (первый event сильно позже) и заканчиваться в `period.end` (последний event
    /// сильно раньше). Returns nil если period degenerate (zero/negative length)
    /// ИЛИ если impl не поддерживает (default extension nil — graceful для stubs).
    func longestUninterruptedWindow(period: DateInterval) throws -> UninterruptedWindow?

    /// Phase 4.6.B — counts моих status transitions в Linear за `period`.
    /// Source filter: events с `signal_type='action' AND source='linear' AND
    /// event_kind='status_transition'`. Default extension возвращает `.empty`
    /// (для StubInsights / iOS-future graceful).
    func linearTransitions(period: DateInterval) throws -> LinearTransitionBreakdown

    /// Phase 4.6.B — soft follow-through ratio = `completed / (completed +
    /// started + reopened)` через тот же aggregator. `nil` ↔ `completed == 0`
    /// (избегает misleading "0% follow-through" в типичный in-progress день).
    /// Default extension возвращает `nil`.
    func linearCompletionRate(period: DateInterval) throws -> Double?

    // Activity lookup (Phase 2.1).
    /// Last attention event, опционально отфильтрованный по `bundleID`.
    /// Возвращает `nil` если matching events нет (пустая БД, неизвестный bundle).
    /// `nil` — semantically valid "нет данных", не error → не throws при empty result.
    func lastActivity(bundleID: String?) throws -> ActivitySnapshot?

    /// Phase 4.10.A — chronological per-event feed for the Activity tab.
    /// Phase 4.10.B — aggregated work sessions for the Activity tab "Sessions"
    /// mode and the Home "Recent sessions" block. Reads `attention` events
    /// (+ `context` boundary markers) within `period`, aggregates via
    /// `SessionFeedMapper`, returns up to `limit` sessions sorted newest-first
    /// (start desc). Default extension returns `[]` so StubInsights / iOS-future
    /// stay no-op without override.
    func recentSessions(period: DateInterval, limit: Int) throws -> [ActivitySession]

    // MARK: - Track 8 P1 — Home operational console substrate

    /// Track-8 P1 — caller's current work context (Linear issue, branch, repo, workspace).
    /// Returns `nil` when underlying presence row is missing entirely; returns a
    /// `TaskIdentity` with `isEmpty == true` when presence exists but no task is pinned.
    /// Default `nil` for stubs / iOS-future.
    func currentTaskIdentity() throws -> TaskIdentity?

    /// Track-10 T2 — caller's current workspace absolute path (ephemeral, in-memory).
    /// Returned separately from `TaskIdentity` because ADR-010 keeps absolute path
    /// bytes OUT of `TaskIdentity` (which flows into `InsightsSnapshot` and could be
    /// MCP-serialized — Track-9 T5 D-8). Consumed by `InsightsReader.refresh()` to
    /// pass into `GitDeltaReader.read(forWorkspacePath:)`; never stored on the
    /// snapshot. Default `nil` for stubs / iOS-future.
    func currentWorkspacePath() throws -> String?

    /// Track-10 T7 — bundled task-session lens consumed by the Home YOU'RE ON
    /// block. Returns nil when no current task can be identified (e.g.,
    /// Terminal-only work, no IDE foreground in attention history). See
    /// `CurrentTaskSession` for field semantics.
    func currentTaskSession() throws -> CurrentTaskSession?

    /// Track-8 P1 — teammates currently working on the same task as caller. Matching
    /// rule is hierarchical (same Linear issue → same branch → adjacent branch).
    /// Returns `[]` when no `presence_history` substrate (pre-Phase 5.4) or no match.
    /// Default `[]` for stubs / iOS-future.
    func sameTaskTeammates(rule: MatchRule) throws -> [TeammateMatch]

    /// Track-8 P1 — items requiring caller's attention: review requests, comments on
    /// my work, @-mentions, open questions, blockers. Filtered + searched per
    /// arguments. Aggregation collapses multiple events on same target into one row.
    /// Default `[]` for stubs / iOS-future.
    func inboxItems(filter: InboxFilter, query: String?) throws -> [InboxItem]

    /// Track-8 P1 — anchor metrics for Home TODAY block: focused-minutes, AI ratio,
    /// sessions count, context switches, commits, plus per-surface event-count pills.
    /// `now: Date` is passed for testability (period derives `today` from local TZ).
    /// Default `.empty` for stubs / iOS-future.
    func todayMetrics(now: Date) throws -> TodayMetrics

    /// Track-8 P1 — current activity state with priority resolution:
    /// inMeeting > deepWorkFocus > away(screenLocked) > away(idle) > active.
    /// `now: Date` for testability. Default `.away(.idle, idleSec: 0)` for stubs.
    func youNowState(now: Date) throws -> YouNowState

    // MARK: - Track-9 T1 — recent commit deriver

    /// Track-9 T1 — most-recent observed gh_commit_pushed event within maxAgeMs.
    /// Returns nil if no commit in window or DB read fails gracefully.
    func recentLastCommit(maxAgeMs: Int64) throws -> RecentCommitSnapshot?

    // MARK: - Track-9 T4 — weekly metrics deriver

    /// Track-9 T4 — 7-day analytics aggregation anchored at local-TZ midnight.
    /// Returns `dailySeries` (7 entries, oldest → newest), peakHour, single-metric
    /// WoW delta (focused-min based), 5 streak counters.
    /// `now: Date` for testability (window derives [today − 6d .. today]).
    /// Default `.empty` for stubs / iOS-future.
    func weeklyMetrics(now: Date) throws -> WeeklyMetrics

    // MARK: - Track-10 T5 — per-event activity feed

    /// Track-10 T5 — per-event activity feed since cursor for SINCE YOU WERE LAST
    /// ACTIVE timeline. Returns most-recent-first rows (`ts DESC`) of allow-listed
    /// Linear/GitHub/Slack event_kinds with `ts > since`, joined with D3
    /// `open_questions` / `blockers` opened/started since the cursor. Impl caps
    /// `limit` at 200 to prevent unbounded memory under stale cursors.
    /// Default `[]` for stubs / iOS-future.
    func recentActivityFeed(since: Int64, limit: Int) throws -> [ActivityFeedItem]

    /// Track-7 P3 substrate — open Blocker rows from M014 `blockers` table.
    /// IV.A.2 partial substrate: integration consumes only the value type
    /// (StandupComposer feeds blockers into RecapBlock/EodBlock UI); full
    /// reader-side implementation lands when Track-7 P3 lands or post-
    /// integration cleanup wires D3 `BlockerPatternHit` as the canonical
    /// source. Default returns `[]` so StubInsights stays no-op.
    func openBlockers() throws -> [Blocker]
}

/// Default implementations — конформер'ы могут override'ить, но без явного
/// override получают `.empty` (opt-in feature, no-data ≠ error).
public extension DerivedInsights {
    func slackActivity(period: DateInterval) throws -> SlackActivityBreakdown { .empty }

    /// Phase 4.6.C.2 — default nil чтобы StubInsights / iOS-future free от обновления.
    func longestUninterruptedWindow(period: DateInterval) throws -> UninterruptedWindow? { nil }

    /// Phase 4.6.B — default `.empty` для StubInsights / iOS-future.
    func linearTransitions(period: DateInterval) throws -> LinearTransitionBreakdown { .empty }

    /// Phase 4.6.B — default `nil` для StubInsights / iOS-future.
    func linearCompletionRate(period: DateInterval) throws -> Double? { nil }

    /// Phase 4.10.B — default empty list для StubInsights / iOS-future.
    func recentSessions(period: DateInterval, limit: Int) throws -> [ActivitySession] { [] }

    /// IV.A.2 partial substrate — Track-7 P3 `openBlockers` default empty
    /// for stubs / iOS-future / integration. Real reader-side impl lands
    /// when Track-7 P3 is fully wired.
    func openBlockers() throws -> [Blocker] { [] }

    // MARK: - Track 8 P1 defaults

    func currentTaskIdentity() throws -> TaskIdentity? { nil }

    /// Track-10 T2 — default `nil` for stubs / iOS-future. Prod impl reuses
    /// `WorkspacePathResolver.resolve(bundleID:db:)` ephemeral lookup.
    public func currentWorkspacePath() throws -> String? { nil }

    /// Track-10 T7 — default `nil` for stubs / iOS-future. Prod impl in
    /// `LeafCorePrivate` composes per-IDE dispatch + dwell walk + basenames.
    public func currentTaskSession() throws -> CurrentTaskSession? { nil }

    public func sameTaskTeammates(rule: MatchRule) throws -> [TeammateMatch] { [] }

    func inboxItems(filter: InboxFilter, query: String?) throws -> [InboxItem] { [] }

    func todayMetrics(now: Date) throws -> TodayMetrics { .empty }

    func youNowState(now: Date) throws -> YouNowState {
        .away(YouNowAway(reason: .idle, lastApp: nil, lastContextLabel: nil,
                         lastLinearID: nil, idleSec: 0))
    }

    // MARK: - Track-9 T1 defaults

    /// Track-9 T1 stub default — returns nil; ProdInsights SQL impl lives in moat.
    func recentLastCommit(maxAgeMs: Int64) throws -> RecentCommitSnapshot? { nil }

    // MARK: - Track-9 T4 defaults

    /// Track-9 T4 stub default — returns `.empty`; ProdInsights SQL impl in LeafCorePrivate moat.
    func weeklyMetrics(now: Date) throws -> WeeklyMetrics { .empty }

    // MARK: - Track-10 T5 default

    /// Track-10 T5 stub default — returns `[]`; ProdInsights SQL impl in LeafCorePrivate moat.
    func recentActivityFeed(since: Int64, limit: Int) throws -> [ActivityFeedItem] { [] }
}

/// Phase 1.1 / CI fallback. Все методы бросают .notImplemented.
public struct StubInsights: DerivedInsights {
    public let database: Database
    public init(database: Database) { self.database = database }

    public func timeInApp(period: DateInterval) throws -> [AppTimeEntry] { throw LeafError.notImplemented }
    public func focusSessions(period: DateInterval) throws -> [FocusSession] { throw LeafError.notImplemented }
    public func contextSwitchRate(period: DateInterval) throws -> Double { throw LeafError.notImplemented }
    public func deepWorkStreak() throws -> DeepWorkStreak { throw LeafError.notImplemented }
    public func peakProductivityHour() throws -> Int? { nil }
    public func filesTouched(period: DateInterval) throws -> [String] { throw LeafError.notImplemented }
    public func aiRatio(period: DateInterval) throws -> Double { 0 }
    public func aiActivityBreakdown(period: DateInterval) throws -> AIActivityBreakdown { .empty }
    public func linearActivity(period: DateInterval) throws -> LinearActivityBreakdown { .empty }
    public func githubActivity(period: DateInterval) throws -> GitHubActivityBreakdown { .empty }
    public func slackActivity(period: DateInterval) throws -> SlackActivityBreakdown { .empty }
    public func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval { throw LeafError.notImplemented }
    public func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double { throw LeafError.notImplemented }
    public func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry] { throw LeafError.notImplemented }
    public func weekOverWeekDelta() throws -> Double? { nil }
    public func activeDaysInRow() throws -> Int { 0 }
    public func lastActivity(bundleID: String?) throws -> ActivitySnapshot? { nil }

    // Track-9 T1 stub default — ProdInsights SQL impl lives in moat.
    public func recentLastCommit(maxAgeMs: Int64) throws -> RecentCommitSnapshot? { nil }

    // Track-9 T4 stub default — ProdInsights SQL impl in LeafCorePrivate moat.
    public func weeklyMetrics(now: Date) throws -> WeeklyMetrics { .empty }
}
