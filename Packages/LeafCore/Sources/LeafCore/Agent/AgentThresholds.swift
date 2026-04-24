import Foundation

/// Tunables для Agent runtime. Production значения — moat (`LeafCorePrivate/Prod/Configs/AgentThresholdsProd.swift`).
/// `weakDefaults` — generic defaults для CI и dev-без-moat сборок.
public struct AgentThresholds: Sendable, Hashable {
    /// Как часто проверять CGEventSource idle.
    public let idlePollIntervalSec: TimeInterval
    /// Сколько секунд без input'а считается idle → пишем context `{state: "idle"}`.
    public let idleThresholdSec: TimeInterval
    /// Как часто EventWriter flush'ит буфер в DB.
    public let eventFlushIntervalSec: TimeInterval
    /// При достижении этого размера буфер flush'ится немедленно (не ждём интервал).
    public let eventFlushBatchSize: Int

    public init(
        idlePollIntervalSec: TimeInterval,
        idleThresholdSec: TimeInterval,
        eventFlushIntervalSec: TimeInterval,
        eventFlushBatchSize: Int
    ) {
        self.idlePollIntervalSec = idlePollIntervalSec
        self.idleThresholdSec = idleThresholdSec
        self.eventFlushIntervalSec = eventFlushIntervalSec
        self.eventFlushBatchSize = eventFlushBatchSize
    }

    public static let weakDefaults = AgentThresholds(
        idlePollIntervalSec: 10,
        idleThresholdSec: 300,
        eventFlushIntervalSec: 5,
        eventFlushBatchSize: 50
    )
}
