import Foundation

/// Track-9 T4 — 7-day analytics aggregation anchored at local-TZ midnight.
/// Pure substrate value type. Read-only deriver output; no capture-path emission.
public struct WeeklyMetrics: Equatable, Hashable, Sendable {
    /// 7 entries, oldest → newest. `dailySeries[0]` = day-6, `dailySeries[6]` = today.
    /// Anchored at local-TZ midnight via `Calendar.current.startOfDay(for:)`.
    public let dailySeries: [DailyMetric]

    /// 0..23 hour bucket with maximum attention-time across the 7-day window.
    /// nil iff total attention < 5 min (insignificant data).
    /// Tie-break: lowest hour wins (determinism).
    public let peakHour: Int?

    /// (this_week_focused - last_week_focused) / last_week_focused.
    /// nil iff last_week_focused == 0 (no comparable baseline).
    public let wowDelta: Double?

    /// Consecutive days back from today w/ ≥1 gh_commit_pushed. Max 7.
    public let commitStreak: Int

    /// Consecutive days back from today w/ ≥1 Linear status_transition.completed. Max 7.
    public let issueCloseStreak: Int

    /// Consecutive days back from today w/ ≥1 slack_huddle_state_change.started. Max 7.
    public let huddleStreak: Int

    /// Consecutive days back from today w/ ≥1 focus session ≥10 min. Max 7.
    public let focusSessionStreak: Int

    /// Consecutive days back from today w/ ≥1 minute satisfying T4 heavy threshold. Max 7.
    public let heavyPulseStreak: Int

    public static let empty = WeeklyMetrics(
        dailySeries: Array(repeating: DailyMetric.empty, count: 7),
        peakHour: nil,
        wowDelta: nil,
        commitStreak: 0,
        issueCloseStreak: 0,
        huddleStreak: 0,
        focusSessionStreak: 0,
        heavyPulseStreak: 0
    )

    public init(
        dailySeries: [DailyMetric],
        peakHour: Int?,
        wowDelta: Double?,
        commitStreak: Int,
        issueCloseStreak: Int,
        huddleStreak: Int,
        focusSessionStreak: Int,
        heavyPulseStreak: Int
    ) {
        self.dailySeries = dailySeries
        self.peakHour = peakHour
        self.wowDelta = wowDelta
        self.commitStreak = commitStreak
        self.issueCloseStreak = issueCloseStreak
        self.huddleStreak = huddleStreak
        self.focusSessionStreak = focusSessionStreak
        self.heavyPulseStreak = heavyPulseStreak
    }
}

/// Track-9 T4 — single-day aggregation slice of WeeklyMetrics.
public struct DailyMetric: Equatable, Hashable, Sendable {
    /// Local-TZ midnight epoch ms for the day.
    public let dayStartMs: Int64

    /// Sum of focus session minutes (≥10 min sessions) that day. Truncated to Int.
    public let focusedMin: Int

    /// Distinct focus sessions ≥10 min that day.
    public let sessionsCount: Int

    /// Count of gh_commit_pushed events that day.
    public let commitsCount: Int

    /// AI ratio 0.0..1.0 for the day; 0.0 if no attention in day.
    public let aiRatio: Double

    public static let empty = DailyMetric(
        dayStartMs: 0, focusedMin: 0, sessionsCount: 0, commitsCount: 0, aiRatio: 0
    )

    public init(
        dayStartMs: Int64, focusedMin: Int, sessionsCount: Int, commitsCount: Int, aiRatio: Double
    ) {
        self.dayStartMs = dayStartMs
        self.focusedMin = focusedMin
        self.sessionsCount = sessionsCount
        self.commitsCount = commitsCount
        self.aiRatio = aiRatio
    }
}
