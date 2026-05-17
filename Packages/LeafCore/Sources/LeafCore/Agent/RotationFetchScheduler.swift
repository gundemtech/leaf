import Foundation
import os

/// Phase 5.3.E — periodic peer-side rotation fetch loop. Drains pending
/// rotations from relay (`RotationFetchService.tick`) + opportunistically
/// resumes admin-side outgoing outbox (`KeyRotationService.resumePendingPosts`)
/// each tick.
///
/// Mirrors `MaintenanceScheduler` actor pattern — single Task loop, await-on-cancel
/// shutdown, weak-self capture. Initial tick at half-interval (mirror retention
/// sweep loop) so first fetch happens within ~30s of Agent start (default 60s).
public actor RotationFetchScheduler {
    private let fetchService: RotationFetchService
    private let keyRotationService: KeyRotationService
    private let intervalSec: TimeInterval
    private let logger: Logger

    private var task: Task<Void, Never>?

    public init(
        fetchService: RotationFetchService,
        keyRotationService: KeyRotationService,
        intervalSec: TimeInterval,
        logger: Logger
    ) {
        self.fetchService = fetchService
        self.keyRotationService = keyRotationService
        self.intervalSec = intervalSec
        self.logger = logger
    }

    public func start() {
        if task != nil { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
        logger.info("RotationFetchScheduler started (every=\(self.intervalSec, privacy: .public)s)")
    }

    public func stop() async {
        task?.cancel()
        await task?.value
        task = nil
        logger.info("RotationFetchScheduler stopped")
    }

    public func performTick() async {
        let outcome = await fetchService.tick()
        if outcome.fetched > 0 || outcome.installed > 0 || outcome.tombstoneApplied > 0 || outcome.skipped > 0 {
            logger.info(
                "rotation fetch tick: fetched=\(outcome.fetched, privacy: .public) installed=\(outcome.installed, privacy: .public) tombstoneApplied=\(outcome.tombstoneApplied, privacy: .public) skipped=\(outcome.skipped, privacy: .public)"
            )
        }
        do {
            let resume = try await keyRotationService.resumePendingPosts()
            if resume.totalCount > 0 {
                logger.info(
                    "rotation outbox resume: posted=\(resume.postedCount, privacy: .public) pending=\(resume.pendingCount, privacy: .public)"
                )
            }
        } catch {
            logger.error("rotation outbox resume failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runLoop() async {
        await sleep(seconds: intervalSec / 2)
        while !Task.isCancelled {
            await performTick()
            await sleep(seconds: intervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }
}
