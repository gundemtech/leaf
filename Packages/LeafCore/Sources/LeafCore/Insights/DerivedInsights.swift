import Foundation

/// 12 функций Derived Insights Engine (см. architecture.md).
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
    func deepWorkStreak() throws -> TimeInterval
    func peakProductivityHour() throws -> Int?

    // Content
    func filesTouched(period: DateInterval) throws -> [String]

    // AI collaboration
    func aiRatio(period: DateInterval) throws -> Double

    // Team (Phase 2+)
    func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval
    func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double
    func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry]

    // Trends
    func weekOverWeekDelta() throws -> Double
    func activeDaysInRow() throws -> Int
}

/// Phase 1.1 / CI fallback. Все методы бросают .notImplemented.
public struct StubInsights: DerivedInsights {
    public let database: Database
    public init(database: Database) { self.database = database }

    public func timeInApp(period: DateInterval) throws -> [AppTimeEntry] { throw LeafError.notImplemented }
    public func focusSessions(period: DateInterval) throws -> [FocusSession] { throw LeafError.notImplemented }
    public func contextSwitchRate(period: DateInterval) throws -> Double { throw LeafError.notImplemented }
    public func deepWorkStreak() throws -> TimeInterval { throw LeafError.notImplemented }
    public func peakProductivityHour() throws -> Int? { throw LeafError.notImplemented }
    public func filesTouched(period: DateInterval) throws -> [String] { throw LeafError.notImplemented }
    public func aiRatio(period: DateInterval) throws -> Double { throw LeafError.notImplemented }
    public func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval { throw LeafError.notImplemented }
    public func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double { throw LeafError.notImplemented }
    public func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry] { throw LeafError.notImplemented }
    public func weekOverWeekDelta() throws -> Double { throw LeafError.notImplemented }
    public func activeDaysInRow() throws -> Int { throw LeafError.notImplemented }
}
