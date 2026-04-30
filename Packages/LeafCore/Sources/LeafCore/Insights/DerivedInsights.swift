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
    /// Action events с `payload_json.source='slack' AND event_kind='message_authored_aggregate'`
    /// дают `messagesCount` (sum of `count` field) + `byChannel` (top-5).
    /// Context events с `event_kind='huddle_state_change'` walk'ом дают `huddleMinutes`.
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

    // Activity lookup (Phase 2.1).
    /// Last attention event, опционально отфильтрованный по `bundleID`.
    /// Возвращает `nil` если matching events нет (пустая БД, неизвестный bundle).
    /// `nil` — semantically valid "нет данных", не error → не throws при empty result.
    func lastActivity(bundleID: String?) throws -> ActivitySnapshot?
}

/// Default implementations — конформер'ы могут override'ить, но без явного
/// override получают `.empty` (opt-in feature, no-data ≠ error).
public extension DerivedInsights {
    func slackActivity(period: DateInterval) throws -> SlackActivityBreakdown { .empty }

    /// Phase 4.6.C.2 — default nil чтобы StubInsights / iOS-future free от обновления.
    func longestUninterruptedWindow(period: DateInterval) throws -> UninterruptedWindow? { nil }
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
}
