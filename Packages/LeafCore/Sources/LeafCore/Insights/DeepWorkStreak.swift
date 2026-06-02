import Foundation

/// Phase 2.2 — consecutive deep-work days series.
///
/// `days == 0` — no streak yet (or no deep sessions today/yesterday).
/// `totalSeconds` — sum of deep-session durations across all days of the streak.
public struct DeepWorkStreak: Codable, Sendable, Hashable {
    public let days: Int
    public let totalSeconds: TimeInterval

    public init(days: Int, totalSeconds: TimeInterval) {
        self.days = days
        self.totalSeconds = totalSeconds
    }

    public static let empty = DeepWorkStreak(days: 0, totalSeconds: 0)
}
