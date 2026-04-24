import Foundation
import os

/// Периодические hygiene-операции: WAL checkpoint + retention sweep.
///
/// Живёт в LeafCore (не в LeafAgent binary), чтобы тестироваться через `LeafCoreTests`
/// без отдельного Xcode test target. В Agent.main() инстанциируется один раз
/// и стартует рядом с EventWriter.
///
/// Два независимых loop'а:
/// - WAL checkpoint раз в `walCheckpointIntervalSec` (первый тик — через полный интервал).
/// - Retention sweep раз в `retentionSweepIntervalSec` (первый тик — через половину,
///   чтобы cleanup случился за одну сессию, а не через полный interval offline).
///
/// Chunked DELETE: sweep вызывает `Database.deleteEventsOlderThan(tsMs:limit:)` в
/// цикле пока возвращается `chunkLimit`. Между чанками — `Task.sleep(200ms)` yield,
/// чтобы writer из EventWriter успевал flush батчей.
///
/// Shutdown: `stop()` cancel'ит оба Task'а и `await task.value` — ждёт завершения
/// in-flight итерации. Без этого `Task.cancel()` **не** прерывает `pool.write { ... }`
/// (GRDB не cancellation-aware), и launchd SIGKILL'ит через 20с.
public actor MaintenanceScheduler {
    private let database: Database
    private let walCheckpointIntervalSec: TimeInterval
    private let retentionSweepIntervalSec: TimeInterval
    private let retentionDays: Int
    private let chunkLimit: Int
    private let logger: Logger

    private var checkpointTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?

    public init(
        database: Database,
        walCheckpointIntervalSec: TimeInterval,
        retentionSweepIntervalSec: TimeInterval,
        retentionDays: Int,
        chunkLimit: Int = 5000,
        logger: Logger
    ) {
        self.database = database
        self.walCheckpointIntervalSec = walCheckpointIntervalSec
        self.retentionSweepIntervalSec = retentionSweepIntervalSec
        self.retentionDays = retentionDays
        self.chunkLimit = chunkLimit
        self.logger = logger
    }

    // MARK: - Public control

    public func start() {
        if checkpointTask == nil {
            checkpointTask = Task { [weak self] in
                await self?.runCheckpointLoop()
            }
        }
        if sweepTask == nil {
            sweepTask = Task { [weak self] in
                await self?.runSweepLoop()
            }
        }
        logger.info("MaintenanceScheduler started (walEvery=\(self.walCheckpointIntervalSec, privacy: .public)s, sweepEvery=\(self.retentionSweepIntervalSec, privacy: .public)s, retentionDays=\(self.retentionDays, privacy: .public))")
    }

    public func stop() async {
        checkpointTask?.cancel()
        sweepTask?.cancel()
        await checkpointTask?.value
        await sweepTask?.value
        checkpointTask = nil
        sweepTask = nil
        logger.info("MaintenanceScheduler stopped")
    }

    // MARK: - Pure actions (unit-testable)

    public func performCheckpoint() async {
        do {
            try database.checkpointWAL()
            logger.debug("WAL checkpoint done")
        } catch {
            logger.error("WAL checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func performRetentionSweep(nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async {
        let cutoff = nowMs - Int64(retentionDays) * 86_400_000
        var total = 0
        while !Task.isCancelled {
            do {
                let deleted = try database.deleteEventsOlderThan(tsMs: cutoff, limit: chunkLimit)
                total += deleted
                if deleted < chunkLimit { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                logger.error("Retention sweep failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        logger.info("Retention sweep: deleted \(total, privacy: .public) rows older than \(self.retentionDays, privacy: .public)d")
    }

    // MARK: - Loops (integration-tested)

    private func runCheckpointLoop() async {
        await sleep(seconds: walCheckpointIntervalSec)
        while !Task.isCancelled {
            await performCheckpoint()
            await sleep(seconds: walCheckpointIntervalSec)
        }
    }

    private func runSweepLoop() async {
        await sleep(seconds: retentionSweepIntervalSec / 2)
        while !Task.isCancelled {
            await performRetentionSweep()
            await sleep(seconds: retentionSweepIntervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }
}
