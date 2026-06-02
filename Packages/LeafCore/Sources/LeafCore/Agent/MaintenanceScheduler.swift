import Foundation
import os

/// Periodic hygiene operations: WAL checkpoint + retention sweep.
///
/// Lives in LeafCore (not the LeafAgent binary) so it can be tested via `LeafCoreTests`
/// without a separate Xcode test target. In Agent.main() it is instantiated once
/// and started alongside EventWriter.
///
/// Two independent loops:
/// - WAL checkpoint once per `walCheckpointIntervalSec` (first tick after a full interval).
/// - Retention sweep once per `retentionSweepIntervalSec` (first tick after half,
///   so cleanup happens within a single session rather than after a full interval offline).
///
/// Chunked DELETE: the sweep calls `Database.deleteEventsOlderThan(tsMs:limit:)` in a
/// loop while it keeps returning `chunkLimit`. Between chunks — a `Task.sleep(200ms)` yield,
/// so the EventWriter's writer can keep flushing batches.
///
/// Shutdown: `stop()` cancels both Tasks and `await task.value` — waits for the
/// in-flight iteration to finish. Without this `Task.cancel()` does **not** interrupt `pool.write { ... }`
/// (GRDB is not cancellation-aware), and launchd SIGKILLs after 20s.
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
        // Phase Track-4 S3 — intensity_aggregates retention. Single DELETE
        // (no chunking — rows are tiny, ~1440/day worst case = 4.3k rows over
        // default 3-day retention; bounded scan).
        // Intentionally runs even if events loop exited via cancellation —
        // bounded + fast, and ensures retention doesn't drift between restarts.
        do {
            try database.purgeIntensityAggregates(before: cutoff)
        } catch {
            logger.error("Intensity aggregates purge failed: \(error.localizedDescription, privacy: .public)")
        }
        logger.info("Retention sweep: deleted \(total, privacy: .public) event rows older than \(self.retentionDays, privacy: .public)d")
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
