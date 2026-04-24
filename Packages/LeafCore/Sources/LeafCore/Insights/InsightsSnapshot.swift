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

    public init(
        topApps: [AppTimeEntry],
        sessions: [FocusSession],
        switchRate: Double,
        deepSessionsCount: Int,
        deepWorkStreak: DeepWorkStreak,
        peakProductivityHour: Int?,
        weekOverWeekDelta: Double?,
        activeDaysInRow: Int
    ) {
        self.topApps = topApps
        self.sessions = sessions
        self.switchRate = switchRate
        self.deepSessionsCount = deepSessionsCount
        self.deepWorkStreak = deepWorkStreak
        self.peakProductivityHour = peakProductivityHour
        self.weekOverWeekDelta = weekOverWeekDelta
        self.activeDaysInRow = activeDaysInRow
    }

    /// Convenience init — рассчитывает `deepSessionsCount` по threshold'у.
    /// Phase 2.2 — trend-поля с default'ами; тестовые callsite'ы (и существующие
    /// 2.1 consumers) не ломаются когда trends ещё не вычислены.
    public init(
        topApps: [AppTimeEntry],
        sessions: [FocusSession],
        switchRate: Double,
        deepSessionMinSec: TimeInterval,
        deepWorkStreak: DeepWorkStreak = .empty,
        peakProductivityHour: Int? = nil,
        weekOverWeekDelta: Double? = nil,
        activeDaysInRow: Int = 0
    ) {
        self.init(
            topApps: topApps,
            sessions: sessions,
            switchRate: switchRate,
            deepSessionsCount: sessions.filter { $0.duration >= deepSessionMinSec }.count,
            deepWorkStreak: deepWorkStreak,
            peakProductivityHour: peakProductivityHour,
            weekOverWeekDelta: weekOverWeekDelta,
            activeDaysInRow: activeDaysInRow
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
    }

    /// Average session duration. `0` если sessions пуст.
    public var avgSessionDuration: TimeInterval {
        guard !sessions.isEmpty else { return 0 }
        return sessions.reduce(0.0) { $0 + $1.duration } / Double(sessions.count)
    }
}
