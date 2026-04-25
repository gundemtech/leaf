import Foundation

/// Phase 2.3 — shared период enum для всех LeafMCP tools (`get_timeline`,
/// `get_ai_activity`, future). Single source of truth для `interval(now:)`
/// логики, чтобы tool'ы не дрейфовали между собой ("today" определяет
/// одинаково везде).
///
/// Nonisolated т.к. вызывается из `actor StdioTransport` (project default —
/// MainActor isolation; но Period — value type, безопасно).
nonisolated enum TimelinePeriod: String, Codable {
    case today = "today"
    case yesterday = "yesterday"
    case last7Days = "last_7_days"

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return DateInterval(start: start, end: end)
        case .yesterday:
            let todayStart = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
            return DateInterval(start: start, end: todayStart)
        case .last7Days:
            let end = now
            let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
            return DateInterval(start: start, end: end)
        }
    }
}
