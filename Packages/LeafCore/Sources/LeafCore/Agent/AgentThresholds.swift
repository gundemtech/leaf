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
    /// Phase 2.5: минимум секунд в новом app чтобы засчитать context switch.
    /// Quick alt-tab peek (Telegram check за <N сек) не должен инфлировать
    /// switches/h. Применяется в `contextSwitchRate` SQL via LEAD(ts) check.
    /// `weakDefault = 0` → no filter (back-compat для тестов); prod значение
    /// в moat. Не влияет на `focusSessions` segmentation — только на switch counter.
    public let contextSwitchMinHoldSec: TimeInterval
    /// Phase 2.2: минимум attention-секунд в день чтобы день считался "active"
    /// в `activeDaysInRow`. Default 1800s = 30min.
    public let activeDayMinAttentionSec: TimeInterval
    /// Phase 2.2: окно аггрегации `peakProductivityHour` — trailing N дней.
    public let peakHourWindowDays: Int
    /// Phase 2.2: минимум active-дней в окне чтобы `peakProductivityHour`
    /// не возвращал nil. Below → insufficient data.
    public let peakHourMinActiveDays: Int
    /// Phase 2.2: минимум active-дней в previous-week окне чтобы
    /// `weekOverWeekDelta` не возвращал nil.
    public let wowBaselineMinActiveDays: Int
    /// Phase 2.3: как часто `ClaudeCodeCollector` сканирует `~/.claude/projects/`
    /// и tail-read'ит .jsonl. Real prod 90s в moat; weakDefault — 120s.
    public let aiCollectIntervalSec: TimeInterval
    /// Phase 2.3: окно "недавних" jsonl-файлов для backfill при первом запуске.
    /// `mtime >= now - backfillWindowDays * 86400s` → читаем с byte_offset=0
    /// (в БД попадёт исторический срез). Иначе skip-backward (offset = file size).
    public let backfillWindowDays: Int
    /// Phase 2.3: путь к Claude Code projects root. Поддерживает leading `~`
    /// (раскрывается callsite-side через `NSString.expandingTildeInPath`).
    public let claudeCodeProjectsPath: String
    /// Phase 2.4: FSEvents stream `latency` (CFTimeInterval) — окно coalescing
    /// ОС'ом до доставки batch'а callback'у. Real prod ~0.5s в moat.
    public let fsEventsLatencySec: TimeInterval
    /// Phase 2.4: poll fallback interval для `FSEventsCollector.reload()` —
    /// belt+suspenders на случай потери Darwin notification.
    public let fsEventsReconfigPollSec: TimeInterval
    /// Phase 2.4: имя `DistributedNotificationCenter` notification, которой
    /// UI сигнализирует Agent'у что watched_folders изменились → reload.
    public let fsEventsRestartTriggerName: String
    /// Phase 2.4: окно coalesce dedup — same `(path, kind)` в этом окне → drop.
    /// Применяется только в Prod router (moat). Stub coalesce игнорирует.
    /// `weakDefault = 0` → effectively no coalesce; точное prod-значение в moat.
    public let fsEventsCoalesceWindowSec: TimeInterval

    public init(
        idlePollIntervalSec: TimeInterval,
        idleThresholdSec: TimeInterval,
        eventFlushIntervalSec: TimeInterval,
        eventFlushBatchSize: Int,
        retentionSweepIntervalSec: TimeInterval,
        retentionDays: Int,
        focusSessionGapSec: TimeInterval,
        deepSessionMinSec: TimeInterval,
        contextSwitchMinHoldSec: TimeInterval = 0,
        activeDayMinAttentionSec: TimeInterval,
        peakHourWindowDays: Int,
        peakHourMinActiveDays: Int,
        wowBaselineMinActiveDays: Int,
        aiCollectIntervalSec: TimeInterval,
        backfillWindowDays: Int,
        claudeCodeProjectsPath: String,
        fsEventsLatencySec: TimeInterval = 0.5,
        fsEventsReconfigPollSec: TimeInterval = 60,
        fsEventsRestartTriggerName: String = "tech.gundem.leaf.watched-folders-changed",
        fsEventsCoalesceWindowSec: TimeInterval = 0
    ) {
        self.idlePollIntervalSec = idlePollIntervalSec
        self.idleThresholdSec = idleThresholdSec
        self.eventFlushIntervalSec = eventFlushIntervalSec
        self.eventFlushBatchSize = eventFlushBatchSize
        self.retentionSweepIntervalSec = retentionSweepIntervalSec
        self.retentionDays = retentionDays
        self.focusSessionGapSec = focusSessionGapSec
        self.deepSessionMinSec = deepSessionMinSec
        self.contextSwitchMinHoldSec = contextSwitchMinHoldSec
        self.activeDayMinAttentionSec = activeDayMinAttentionSec
        self.peakHourWindowDays = peakHourWindowDays
        self.peakHourMinActiveDays = peakHourMinActiveDays
        self.wowBaselineMinActiveDays = wowBaselineMinActiveDays
        self.aiCollectIntervalSec = aiCollectIntervalSec
        self.backfillWindowDays = backfillWindowDays
        self.claudeCodeProjectsPath = claudeCodeProjectsPath
        self.fsEventsLatencySec = fsEventsLatencySec
        self.fsEventsReconfigPollSec = fsEventsReconfigPollSec
        self.fsEventsRestartTriggerName = fsEventsRestartTriggerName
        self.fsEventsCoalesceWindowSec = fsEventsCoalesceWindowSec
    }

    public static let weakDefaults = AgentThresholds(
        idlePollIntervalSec: 10,
        idleThresholdSec: 300,
        eventFlushIntervalSec: 5,
        eventFlushBatchSize: 50,
        retentionSweepIntervalSec: 86_400,
        retentionDays: 365,
        focusSessionGapSec: 600,
        deepSessionMinSec: 1500,
        contextSwitchMinHoldSec: 0,
        activeDayMinAttentionSec: 1800,
        peakHourWindowDays: 14,
        peakHourMinActiveDays: 7,
        wowBaselineMinActiveDays: 2,
        aiCollectIntervalSec: 120,
        backfillWindowDays: 7,
        claudeCodeProjectsPath: "~/.claude/projects",
        fsEventsLatencySec: 0.5,
        fsEventsReconfigPollSec: 60,
        fsEventsRestartTriggerName: "tech.gundem.leaf.watched-folders-changed",
        fsEventsCoalesceWindowSec: 0
    )
}
