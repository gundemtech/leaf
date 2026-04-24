import Foundation

/// Phase 2.2 — consecutive deep-work days series.
///
/// `days == 0` — seriya не набрана (или сегодня/вчера нет deep session'ов).
/// `totalSeconds` — сумма deep-session durations во все дни streak'а.
public struct DeepWorkStreak: Codable, Sendable, Hashable {
    public let days: Int
    public let totalSeconds: TimeInterval

    public init(days: Int, totalSeconds: TimeInterval) {
        self.days = days
        self.totalSeconds = totalSeconds
    }

    public static let empty = DeepWorkStreak(days: 0, totalSeconds: 0)
}
