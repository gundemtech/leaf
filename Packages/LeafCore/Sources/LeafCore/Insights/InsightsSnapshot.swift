import Foundation

/// View-model для popover (и любого другого consumer'а) — агрегированный
/// результат одного refresh-цикла Derived Insights Engine.
///
/// Phase 2.1 — три метрики (timeInApp + sessions + switchRate). Phase 2.2
/// расширит trends-полями (deepWorkStreak / peakHour / wow / activeDaysInRow);
/// Phase 2.3 — `aiRatio`. Расширение через optional fields с default `nil` —
/// не ломает existing consumers.
///
/// Snapshot consider'ится empty если ВСЕ три текущих метрики пусты/zero.
/// Partial-empty (есть topApps, нет sessions) — `.loaded` с placeholder в
/// Sessions-блоке UI.
public struct InsightsSnapshot: Sendable, Hashable {
    public let topApps: [AppTimeEntry]
    public let sessions: [FocusSession]
    /// Switches per active hour. `0.0` если active hours == 0.
    public let switchRate: Double
    /// Precomputed: count of sessions с `duration >= deepSessionMinSec`.
    /// Делается на producer-side чтобы UI не таскал threshold.
    public let deepSessionsCount: Int

    public init(
        topApps: [AppTimeEntry],
        sessions: [FocusSession],
        switchRate: Double,
        deepSessionsCount: Int
    ) {
        self.topApps = topApps
        self.sessions = sessions
        self.switchRate = switchRate
        self.deepSessionsCount = deepSessionsCount
    }

    /// Convenience init — рассчитывает `deepSessionsCount` по threshold'у.
    public init(
        topApps: [AppTimeEntry],
        sessions: [FocusSession],
        switchRate: Double,
        deepSessionMinSec: TimeInterval
    ) {
        self.init(
            topApps: topApps,
            sessions: sessions,
            switchRate: switchRate,
            deepSessionsCount: sessions.filter { $0.duration >= deepSessionMinSec }.count
        )
    }

    public var isEmpty: Bool {
        topApps.isEmpty && sessions.isEmpty && switchRate == 0
    }

    /// Average session duration. `0` если sessions пуст.
    public var avgSessionDuration: TimeInterval {
        guard !sessions.isEmpty else { return 0 }
        return sessions.reduce(0.0) { $0 + $1.duration } / Double(sessions.count)
    }
}
