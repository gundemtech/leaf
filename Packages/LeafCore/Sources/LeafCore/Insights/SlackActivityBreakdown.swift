import Foundation

/// Phase 4.4 — Slack activity for DerivedInsights.slackActivity(period:).
/// Metadata only — channel name (with DM-anonymization "DM" bucket),
/// per-channel message counts (NO bodies), huddle minutes — derived from
/// context events (state transitions). ADR-010 enforced on the
/// ProdSlackAPIProvider parser side (bodies are discarded before writing into RawEvent).
public struct SlackActivityBreakdown: Sendable, Hashable {
    /// Sum of all `count` values from action events with
    /// `payload.source='slack' AND event_kind='slack_message_authored_aggregate'`
    /// within the period window.
    public let messagesCount: Int
    /// Total minutes the user spent in a huddle within the period window. Computed by walking
    /// pairs of context events `huddle_state_change` (in_a_huddle → default_unset),
    /// clipped to the period boundaries.
    public let huddleMinutes: Int
    /// Top-5 channel buckets by count, descending. DM channels are already
    /// merged into a single "DM" bucket before write (ADR-010 anonymization).
    public let byChannel: [ChannelCountEntry]
    /// Phase 4.6.A.3 — sum of reactions on authored messages over `period` (aggregate
    /// numeric only). `nil` ↔ no message events with a populated reactions_count
    /// (old pre-4.6 events / 0 reactions — indistinguishable, UI conditional on > 0).
    public let reactionsReceived: Int?
    /// Phase 4.6.A.3 — distribution of huddle session durations (clipped to
    /// the period boundaries). `nil` ↔ samples=0 (no pairs of transitions in the window).
    /// Distinguishes "one 45m huddle" from "five 9m huddles" (same huddleMinutes total).
    public let huddleSessionStats: LatencyStats?
    /// Phase 4.6.C.1 — reserved for per-provider WoW in 4.7+. Currently always nil.
    public let wowDeltaPct: Double?
    /// Phase 4.6.C.3 — consecutive days with ≥1 huddle begin-transition
    /// (event_kind='slack_huddle_state_change' AND state='in_a_huddle'),
    /// ending today/yesterday. 60-day lookback, independent of `period`.
    /// `nil` ↔ streak=0.
    public let huddleParticipationStreak: Int?

    public init(
        messagesCount: Int,
        huddleMinutes: Int,
        byChannel: [ChannelCountEntry],
        reactionsReceived: Int? = nil,
        huddleSessionStats: LatencyStats? = nil,
        wowDeltaPct: Double? = nil,
        huddleParticipationStreak: Int? = nil
    ) {
        self.messagesCount = messagesCount
        self.huddleMinutes = huddleMinutes
        self.byChannel = byChannel
        self.reactionsReceived = reactionsReceived
        self.huddleSessionStats = huddleSessionStats
        self.wowDeltaPct = wowDeltaPct
        self.huddleParticipationStreak = huddleParticipationStreak
    }

    public static let empty = SlackActivityBreakdown(
        messagesCount: 0,
        huddleMinutes: 0,
        byChannel: [],
        reactionsReceived: nil,
        huddleSessionStats: nil,
        wowDeltaPct: nil,
        huddleParticipationStreak: nil
    )

    public struct ChannelCountEntry: Sendable, Hashable, Codable {
        public let channelName: String
        public let count: Int
        public init(channelName: String, count: Int) {
            self.channelName = channelName
            self.count = count
        }
    }
}
