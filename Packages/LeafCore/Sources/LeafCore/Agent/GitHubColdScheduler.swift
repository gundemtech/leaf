import Foundation
import os

/// Phase Track-3 D2 — 4am local anchor scheduler for GitHubColdCollector.
///
/// On start: reads `github:cold:<login>` offset from collector_offsets. If
/// absent or `now - lastColdRunMs > 24h`, performs catch-up tick immediately.
/// Then loops: compute next local 4am (via Calendar.current), Task.sleep until
/// then, perform tick, repeat. If the Mac is asleep across 4am, Task.sleep
/// continues on wake — tick fires at first wake-after-4am (accepted "off-hours
/// rough" behavior, mirrors LinearColdScheduler precedent).
public actor GitHubColdScheduler {
    private let database: Database
    private let collector: GitHubColdCollector
    private let loginProvider: @Sendable () -> String?
    private let logger: Logger
    /// Override clock for tests.
    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    private var task: Task<Void, Never>?

    public init(
        database: Database,
        collector: GitHubColdCollector,
        loginProvider: @escaping @Sendable () -> String?,
        logger: Logger,
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = Calendar.current
    ) {
        self.database = database
        self.collector = collector
        self.loginProvider = loginProvider
        self.logger = logger
        self.clock = clock
        self.calendar = calendar
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.runLoop() }
        logger.info("GitHubColdScheduler started")
    }

    public func stop() async {
        task?.cancel()
        await task?.value
        task = nil
        logger.info("GitHubColdScheduler stopped")
    }

    /// Compute the next local 4:00am after `now` (or `now` itself if 4am has
    /// not yet occurred today). Exposed for unit testing.
    ///
    /// `nonisolated` — reads only the immutable `calendar` `let` property; no
    /// actor state mutated. Lets tests call without `await`.
    nonisolated public func nextLocal4am(after now: Date) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 4
        components.minute = 0
        components.second = 0
        guard let candidate = calendar.date(from: components) else { return now }
        if candidate > now { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    /// Catch-up check: returns true when offset absent OR (now - lastColdMs) > 24h.
    ///
    /// `nonisolated` — pure function, touches no instance state. Lets tests
    /// call without `await`.
    nonisolated public func shouldCatchUp(now: Date, lastColdMs: Int64?) -> Bool {
        guard let lastMs = lastColdMs else { return true }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return nowMs - lastMs > 24 * 60 * 60 * 1000
    }

    private func runLoop() async {
        // Initial catch-up gate.
        let now = clock()
        if let login = loginProvider() {
            let offset = try? database.readOffset(
                collectorID: CollectorID.githubColdPolling, sourceID: "github:cold:\(login)")
            if shouldCatchUp(now: now, lastColdMs: offset?.lastModifiedMs) {
                _ = await collector.performTick(now: now)
            }
        } else {
            // No integration yet — skip catch-up, just wait for next 4am.
        }

        while !Task.isCancelled {
            let now = clock()
            let next = nextLocal4am(after: now)
            let deltaSec = max(0, next.timeIntervalSince(now))
            try? await Task.sleep(nanoseconds: UInt64(deltaSec * 1_000_000_000))
            if Task.isCancelled { break }
            _ = await collector.performTick(now: clock())
        }
    }
}
