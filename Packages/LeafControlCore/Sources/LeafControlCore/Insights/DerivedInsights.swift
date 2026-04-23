import Foundation

/// 12 функций Derived Insights Engine (см. architecture.md).
/// Phase 0 — только сигнатуры + default bodies которые throw .notImplemented.
/// Phase 1+ — реальные SQL тела в LeafControlCorePrivate/Insights/*+Impl.swift.
public protocol DerivedInsights: Sendable {
    associatedtype DB: DatabaseAccess

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

/// Phase-0 заглушка: все методы бросают .notImplemented.
/// Реальный провайдер — Phase 1, из LeafControlCorePrivate.
public struct UnimplementedInsights<DB: DatabaseAccess>: DerivedInsights {
    public init() {}

    public func timeInApp(period: DateInterval) throws -> [AppTimeEntry] { throw LeafControlError.notImplemented }
    public func focusSessions(period: DateInterval) throws -> [FocusSession] { throw LeafControlError.notImplemented }
    public func contextSwitchRate(period: DateInterval) throws -> Double { throw LeafControlError.notImplemented }
    public func deepWorkStreak() throws -> TimeInterval { throw LeafControlError.notImplemented }
    public func peakProductivityHour() throws -> Int? { throw LeafControlError.notImplemented }
    public func filesTouched(period: DateInterval) throws -> [String] { throw LeafControlError.notImplemented }
    public func aiRatio(period: DateInterval) throws -> Double { throw LeafControlError.notImplemented }
    public func teamPresenceOverlap(team: [String], period: DateInterval) throws -> TimeInterval { throw LeafControlError.notImplemented }
    public func teamFocusAlignment(team: [String], period: DateInterval) throws -> Double { throw LeafControlError.notImplemented }
    public func teamTimeline(team: [String], period: DateInterval) throws -> [AppTimeEntry] { throw LeafControlError.notImplemented }
    public func weekOverWeekDelta() throws -> Double { throw LeafControlError.notImplemented }
    public func activeDaysInRow() throws -> Int { throw LeafControlError.notImplemented }
}
