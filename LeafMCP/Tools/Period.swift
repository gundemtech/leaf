import Foundation

/// Phase 2.3 — shared period enum for all LeafMCP tools (`get_timeline`,
/// `get_ai_activity`, future). Single source of truth for the `interval(now:)`
/// logic, so tools don't drift apart ("today" is defined
/// the same way everywhere).
///
/// Nonisolated because it is called from `actor StdioTransport` (project default —
/// MainActor isolation; but Period is a value type, so it's safe).
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
