import Foundation

/// Phase 4.4 — Slack activity для DerivedInsights.slackActivity(period:).
/// Метаданные only — channel name (с DM-anonymization "DM" bucket'ом),
/// per-channel message counts (NO bodies), huddle minutes — derived из
/// context events (state transitions). ADR-010 enforced на стороне
/// ProdSlackAPIProvider parser'а (bodies discard'ятся до записи в RawEvent).
public struct SlackActivityBreakdown: Sendable, Hashable {
    /// Sum всех `count` значений из action events с
    /// `payload.source='slack' AND event_kind='slack_message_authored_aggregate'`
    /// в окне periodа.
    public let messagesCount: Int
    /// Total minutes юзер провёл в huddle'е в окне periodа. Считается walk'ом
    /// пар context events `huddle_state_change` (in_a_huddle → default_unset),
    /// clipped к границам periodа.
    public let huddleMinutes: Int
    /// Top-5 channel bucket'ов по count, descending. DM channels уже
    /// слиты в один "DM" bucket до записи (ADR-010 anonymization).
    public let byChannel: [ChannelCountEntry]
    /// Phase 4.6.A.3 — sum реакций на authored messages за `period` (aggregate
    /// numeric only). `nil` ↔ нет message events с populated reactions_count
    /// (старые pre-4.6 events / 0 реакций — индистигвишабл, UI conditional на > 0).
    public let reactionsReceived: Int?
    /// Phase 4.6.A.3 — distribution длительностей huddle sessions (clipped к
    /// границам periodа). `nil` ↔ samples=0 (не было пар transitions в окне).
    /// Отличает "одна 45m huddle" от "пять 9m huddles" (тот же huddleMinutes total).
    public let huddleSessionStats: LatencyStats?
    /// Phase 4.6.C.1 — reserved под per-provider WoW в 4.7+. Сейчас всегда nil.
    public let wowDeltaPct: Double?
    /// Phase 4.6.C.3 — consecutive days с ≥1 huddle begin-transition
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

    public static let empty = Self(
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
