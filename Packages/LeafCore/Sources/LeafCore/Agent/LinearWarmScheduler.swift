import Foundation
import os

/// Phase Track-3 D1 — 15m interval scheduler for LinearWarmCollector.
/// Mirrors RotationFetchScheduler shape: single Task loop, await-on-cancel
/// shutdown, half-interval initial delay (avoid colliding with hot 5m tick).
public actor LinearWarmScheduler {
    private let collector: LinearWarmCollector
    private let intervalSec: TimeInterval
    private let logger: Logger
    private var task: Task<Void, Never>?

    public init(collector: LinearWarmCollector, intervalSec: TimeInterval, logger: Logger) {
        self.collector = collector
        self.intervalSec = intervalSec
        self.logger = logger
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.runLoop() }
        logger.info("LinearWarmScheduler started (every=\(self.intervalSec, privacy: .public)s)")
    }

    public func stop() async {
        task?.cancel()
        await task?.value
        task = nil
        logger.info("LinearWarmScheduler stopped")
    }

    public func performTick() async {
        _ = await collector.performTick()
    }

    private func runLoop() async {
        await sleep(seconds: intervalSec / 2)
        while !Task.isCancelled {
            await performTick()
            await sleep(seconds: intervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
