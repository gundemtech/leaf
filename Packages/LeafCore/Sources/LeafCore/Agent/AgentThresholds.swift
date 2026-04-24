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
    /// Как часто MaintenanceScheduler запускает retention sweep (DELETE старых events).
    public let retentionSweepIntervalSec: TimeInterval
    /// Cutoff: events с `ts < now - retentionDays * 86400s` удаляются sweep'ом.
    public let retentionDays: Int
    /// Phase 2.1: gap между двумя consecutive attention events, после которого
    /// session считается завершённой. Default `idleThresholdSec * 2` —
    /// "две пропущенных idle-checkpoint'а = сессия закончилась".
    public let focusSessionGapSec: TimeInterval
    /// Phase 2.1: минимальная длительность session чтобы считаться "deep".
    /// Default 1500s = 25min (Pomodoro lower bound).
    public let deepSessionMinSec: TimeInterval

    public init(
        idlePollIntervalSec: TimeInterval,
        idleThresholdSec: TimeInterval,
        eventFlushIntervalSec: TimeInterval,
        eventFlushBatchSize: Int,
        retentionSweepIntervalSec: TimeInterval,
        retentionDays: Int,
        focusSessionGapSec: TimeInterval,
        deepSessionMinSec: TimeInterval
    ) {
        self.idlePollIntervalSec = idlePollIntervalSec
        self.idleThresholdSec = idleThresholdSec
        self.eventFlushIntervalSec = eventFlushIntervalSec
        self.eventFlushBatchSize = eventFlushBatchSize
        self.retentionSweepIntervalSec = retentionSweepIntervalSec
        self.retentionDays = retentionDays
        self.focusSessionGapSec = focusSessionGapSec
        self.deepSessionMinSec = deepSessionMinSec
    }

    public static let weakDefaults = AgentThresholds(
        idlePollIntervalSec: 10,
        idleThresholdSec: 300,
        eventFlushIntervalSec: 5,
        eventFlushBatchSize: 50,
        retentionSweepIntervalSec: 86_400,
        retentionDays: 365,
        focusSessionGapSec: 600,
        deepSessionMinSec: 1500
    )
}
