import Foundation

/// Phase 4.4 — Slack activity для DerivedInsights.slackActivity(period:).
/// Метаданные only — channel name (с DM-anonymization "DM" bucket'ом),
/// per-channel message counts (NO bodies), huddle minutes — derived из
/// context events (state transitions). ADR-010 enforced на стороне
/// ProdSlackAPIProvider parser'а (bodies discard'ятся до записи в RawEvent).
public struct SlackActivityBreakdown: Sendable, Hashable {
    /// Sum всех `count` значений из action events с
    /// `payload.source='slack' AND event_kind='message_authored_aggregate'`
    /// в окне periodа.
    public let messagesCount: Int
    /// Total minutes юзер провёл в huddle'е в окне periodа. Считается walk'ом
    /// пар context events `huddle_state_change` (in_a_huddle → default_unset),
    /// clipped к границам periodа.
    public let huddleMinutes: Int
    /// Top-5 channel bucket'ов по count, descending. DM channels уже
    /// слиты в один "DM" bucket до записи (ADR-010 anonymization).
    public let byChannel: [ChannelCountEntry]

    public init(messagesCount: Int, huddleMinutes: Int, byChannel: [ChannelCountEntry]) {
        self.messagesCount = messagesCount
        self.huddleMinutes = huddleMinutes
        self.byChannel = byChannel
    }

    public static let empty = SlackActivityBreakdown(messagesCount: 0, huddleMinutes: 0, byChannel: [])

    public struct ChannelCountEntry: Sendable, Hashable, Codable {
        public let channelName: String
        public let count: Int
        public init(channelName: String, count: Int) {
            self.channelName = channelName
            self.count = count
        }
    }
}
