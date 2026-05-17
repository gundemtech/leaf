import Foundation
import os

/// Phase Track-1 D3 — periodic invocation of `DetectorPipeline.runIncremental`
/// (post-collector-flush detection pass) and `DetectorPipeline.runScheduled`
/// (idle-cadence aggregate scanners: LinearStuck + WhereStopped).
///
/// **Architectural choice — periodic timer over per-flush hook.** The plan's
/// prose described a strict "post-flush" wiring inside Agent's tick loop, but
/// `writeEventsOffsetAndPresence` is invoked from inside individual collectors
/// (LinearCollector/GitHubCollector/SlackCollector), not from Agent.swift
/// directly. Coupling the detector layer to each collector would invert the
/// dependency direction (collectors should not know about detectors). Since
/// the cursor model in `detector_offsets` is incremental and idempotent
/// (per-event INSERT OR IGNORE), running on a timer is functionally equivalent
/// to a strict per-flush hook with at most one `intervalSec` of detection
/// latency — and keeps the moat boundary clean.
///
/// Mirrors `MaintenanceScheduler` actor pattern: single Task per timer,
/// await-on-cancel shutdown, weak-self capture, initial half-interval delay
/// so the first tick lands ~half a period after Agent start.
///
/// Errors from detector passes are logged but **never propagated** — moat
/// implementations are best-effort, and a detector bug must not stall any
/// other Agent subsystem. The collector tick path is wholly independent.
public actor DetectorScheduler {
    private let database: Database
    private let moat: DetectorMoat
    private let incrementalIntervalSec: TimeInterval
    private let scheduledIntervalSec: TimeInterval
    private let logger: Logger

    private var incrementalTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?

    public init(
        database: Database,
        moat: DetectorMoat,
        incrementalIntervalSec: TimeInterval,
        scheduledIntervalSec: TimeInterval,
        logger: Logger
    ) {
        self.database = database
        self.moat = moat
        self.incrementalIntervalSec = incrementalIntervalSec
        self.scheduledIntervalSec = scheduledIntervalSec
        self.logger = logger
    }

    public func start() {
        if incrementalTask == nil {
            incrementalTask = Task { [weak self] in
                await self?.runIncrementalLoop()
            }
        }
        if scheduledTask == nil {
            scheduledTask = Task { [weak self] in
                await self?.runScheduledLoop()
            }
        }
        logger.info(
            "DetectorScheduler started (incremental=\(self.incrementalIntervalSec, privacy: .public)s scheduled=\(self.scheduledIntervalSec, privacy: .public)s)"
        )
    }

    public func stop() async {
        incrementalTask?.cancel()
        scheduledTask?.cancel()
        await incrementalTask?.value
        await scheduledTask?.value
        incrementalTask = nil
        scheduledTask = nil
        logger.info("DetectorScheduler stopped")
    }

    /// One incremental pass — exposed for tests + opportunistic invocation.
    public func performIncrementalTick() {
        do {
            try DetectorPipeline.runIncremental(moat: moat, in: database)
        } catch {
            // Detector failure must NOT stall the Agent. Log + move on; the
            // cursor still advances inside the pipeline so a transient failure
            // doesn't trap us re-processing the same event each tick.
            logger.error("DetectorPipeline.runIncremental failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One scheduled (idle) pass — LinearStuck + WhereStopped.
    public func performScheduledTick() {
        do {
            try DetectorPipeline.runScheduled(moat: moat, in: database)
        } catch {
            logger.error("DetectorPipeline.runScheduled failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runIncrementalLoop() async {
        await sleep(seconds: incrementalIntervalSec / 2)
        while !Task.isCancelled {
            performIncrementalTick()
            await sleep(seconds: incrementalIntervalSec)
        }
    }

    private func runScheduledLoop() async {
        await sleep(seconds: scheduledIntervalSec / 2)
        while !Task.isCancelled {
            performScheduledTick()
            await sleep(seconds: scheduledIntervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }
}
