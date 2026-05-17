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

    /// Track 7 P2 — Xcode build/test activity breakdown for `period`.
    /// Reads `signal_type='content'` (or whatever Track-6 P2 emitter uses)
    /// events with `event_kind IN ('xcode_build_started', 'xcode_build_finished',
    /// 'xcode_test_run_started', 'xcode_test_run_finished', 'xcode_scheme_changed',
    /// 'xcode_run_destination_changed')`. Xcode not enabled → `.empty`.
    func xcodeActivityBreakdown(period: DateInterval) throws -> XcodeActivityBreakdown

    /// Track 7 P2 — IDE file/workspace activity for `period`. Reads events with
    /// `event_kind IN ('vscode_active_doc_changed', 'vscode_workspace_opened',
    /// 'jetbrains_recent_project_observed', 'ide_window_title_observed')`. Groups
    /// by IDE family via `IDEFamilyClassifier`. IDE observers off → `.empty`.
    func idesActivityBreakdown(period: DateInterval) throws -> IDEsActivityBreakdown

    /// Track 7 P2 — Browser navigation / activation / bookmark events for `period`.
    /// Reads `*_tab_navigated`, `*_tab_activated`, `*_bookmark_changed` event_kinds
    /// across Safari / Chrome / Arc. Domain extraction via `URLDomainExtractor`.
    /// All allow-listed; non-allow-listed domains never appear in DB upstream.
    /// Browsers off → `.empty`.
    func browsersActivityBreakdown(period: DateInterval) throws -> BrowsersActivityBreakdown

    /// Track 7 P2 — Zoom meeting duration + calendar linkage for `period`.
    /// Reads `zoom_meeting_started`, `zoom_meeting_ended`, `zoom_meeting_calendar_linked`.
    /// Linkage count via LEFT JOIN on `event_links` where `link_kind='zoom_to_calendar_meeting'`.
    /// Zoom off → `.empty`.
    func zoomActivityBreakdown(period: DateInterval) throws -> ZoomActivityBreakdown

    /// Track 7 P2 — Google Calendar focus / OOO / working-location activity for `period`.
    /// Reads `google_calendar_focus_block_started`, `google_calendar_focus_block_ended`,
    /// `google_calendar_ooo_block_started`, `google_calendar_ooo_block_ended`,
    /// `google_calendar_working_location_changed`. Card-only in P2-collapsed —
    /// detail screen renders empty-state until GCP gate clears. OAuth not connected
    /// or no events → `.empty`.
    func googleCalendarActivityBreakdown(period: DateInterval) throws -> GoogleCalendarActivityBreakdown

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
    /// Returns up to `limit` most-recent events from `period`, mapped to
    /// `ActivityFeedEntry` via `ActivityFeedMapper`. State-pulse event_kinds
    /// (presence / workload / queue counters) are skipped — they belong on
    /// the Live Presence widget. Default extension returns `[]` so StubInsights
    /// stays no-op without override.
    func recentActivity(period: DateInterval, limit: Int) throws -> [ActivityFeedEntry]

    /// Phase 4.10.B — aggregated work sessions for the Activity tab "Sessions"
    /// mode and the Home "Recent sessions" block. Reads `attention` events
    /// (+ `context` boundary markers) within `period`, aggregates via
    /// `SessionFeedMapper`, returns up to `limit` sessions sorted newest-first
    /// (start desc). Default extension returns `[]` so StubInsights / iOS-future
    /// stay no-op without override.
    func recentSessions(period: DateInterval, limit: Int) throws -> [ActivitySession]

    // MARK: - Work State (Track 7 P3 / Track-1 D3 surface)

    /// Phase Track-7 P3 — Decisions detected by Track-1 D3 `DecisionDetector`.
    /// Source: M014 `decisions` table, filtered by `detected_at_ms` in `period`,
    /// sorted DESC, capped client-side by view-model (`limit` is an upstream
    /// hint, not a hard contract). Default `[]` for stubs / iOS-future.
    func recentDecisions(period: DateInterval, limit: Int) throws -> [Decision]

    /// Phase Track-7 P3 — Questions captured by `OpenQuestionDetector`. Returns
    /// ALL questions touching `period` (both `opened_at_ms` in period and
    /// `resolved_at_ms` in period for resolved ones). View-model partitions
    /// open vs resolved client-side. Default `[]` for stubs / iOS-future.
    func openQuestions(period: DateInterval) throws -> [OpenQuestion]

    /// Phase Track-7 P3 — Currently open blockers (`resolved_at_ms IS NULL`).
    /// Life-of-blocker semantics — no period filter; an old blocker that's
    /// still open is still returned. Default `[]` for stubs / iOS-future.
    func openBlockers() throws -> [Blocker]

    /// Phase Track-7 P3 — Most recent "where you stopped" snapshots from
    /// `WhereStoppedDeriver`. Sorted DESC by `generated_at_ms`, capped
    /// client-side. Default `[]` for stubs / iOS-future.
    func recentWhereStopped(limit: Int) throws -> [WhereStoppedSnapshot]
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

    /// Phase 4.10.A — default empty feed для StubInsights / iOS-future / любого
    /// конформера, который ещё не имплементил raw-events SELECT.
    func recentActivity(period: DateInterval, limit: Int) throws -> [ActivityFeedEntry] { [] }

    /// Phase 4.10.B — default empty list для StubInsights / iOS-future.
    func recentSessions(period: DateInterval, limit: Int) throws -> [ActivitySession] { [] }

    /// Track 7 P2 — default `.empty` so StubInsights / iOS-future stay no-op.
    func xcodeActivityBreakdown(period: DateInterval) throws -> XcodeActivityBreakdown { .empty }
    func idesActivityBreakdown(period: DateInterval) throws -> IDEsActivityBreakdown { .empty }
    func browsersActivityBreakdown(period: DateInterval) throws -> BrowsersActivityBreakdown { .empty }
    func zoomActivityBreakdown(period: DateInterval) throws -> ZoomActivityBreakdown { .empty }
    func googleCalendarActivityBreakdown(period: DateInterval) throws -> GoogleCalendarActivityBreakdown { .empty }

    /// Phase Track-7 P3 — default `[]` for stubs / iOS-future.
    func recentDecisions(period: DateInterval, limit: Int) throws -> [Decision] { [] }

    /// Phase Track-7 P3 — default `[]` for stubs / iOS-future.
    func openQuestions(period: DateInterval) throws -> [OpenQuestion] { [] }

    /// Phase Track-7 P3 — default `[]` for stubs / iOS-future.
    func openBlockers() throws -> [Blocker] { [] }

    /// Phase Track-7 P3 — default `[]` for stubs / iOS-future.
    func recentWhereStopped(limit: Int) throws -> [WhereStoppedSnapshot] { [] }
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
    public func xcodeActivityBreakdown(period: DateInterval) throws -> XcodeActivityBreakdown { .empty }
    public func idesActivityBreakdown(period: DateInterval) throws -> IDEsActivityBreakdown { .empty }
    public func browsersActivityBreakdown(period: DateInterval) throws -> BrowsersActivityBreakdown { .empty }
    public func zoomActivityBreakdown(period: DateInterval) throws -> ZoomActivityBreakdown { .empty }
    public func googleCalendarActivityBreakdown(period: DateInterval) throws -> GoogleCalendarActivityBreakdown { .empty }
}
