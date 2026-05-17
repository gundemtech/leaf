import Foundation
import os

/// Phase 2.4 — content collector для file events в watched folders.
///
/// Pattern идентичен `ClaudeCodeCollector`: actor + start/stop с cancel + await,
/// reconfig через `DistributedNotificationCenter` + 60s polling fallback.
///
/// Lifecycle:
///   1. `start()` — `listWatchedFolders` → создать `FSEventStream` →
///      schedule notify listener + poll task.
///   2. FSEvents callback → `handleBatch` (via Task hop из `FSEventStream` onEvents).
///   3. `reload()` — diff с currentPaths → restart stream если diff.
///   4. `stop()` — cancel poll task, await, invalidate stream, remove observer.
public actor FSEventsCollector {
    private let database: Database
    private let router: any FSEventsRouting
    private let logger: Logger
    private let reconfigPollSec: TimeInterval
    private let latencySec: TimeInterval
    private let darwinNotificationName: String

    private var stream: FSEventStream?
    private var pollTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?
    /// Canonical paths текущего активного stream'а. Sorted для детерминистического
    /// сравнения в reload (paths order сам по себе для FSEvents не важен).
    private var currentPaths: [String] = []
    /// Snapshot of enabled watched folders, refreshed синхронно с stream restart.
    /// Передаётся в router на каждый event для granularity / wf_id resolution.
    private var currentFolders: [WatchedFolder] = []

    public init(
        database: Database,
        router: any FSEventsRouting,
        reconfigPollSec: TimeInterval,
        latencySec: TimeInterval,
        darwinNotificationName: String,
        logger: Logger
    ) {
        self.database = database
        self.router = router
        self.reconfigPollSec = reconfigPollSec
        self.latencySec = latencySec
        self.darwinNotificationName = darwinNotificationName
        self.logger = logger
    }

    // MARK: - Public control

    public func start() async {
        guard pollTask == nil else { return }

        // Initial load + stream creation.
        await rebuildStream()

        // Darwin notification listener — UI postит при add/remove/toggle.
        let name = NSNotification.Name(darwinNotificationName)
        notifyToken = DistributedNotificationCenter.default().addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.reload() }
        }

        // Polling fallback — на случай потерянного notify.
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.runPollLoop()
        }

        logger.info(
            "FSEventsCollector started (watching=\(self.currentPaths.count, privacy: .public), poll=\(self.reconfigPollSec, privacy: .public)s)"
        )
    }

    public func stop() async {
        pollTask?.cancel()
        await pollTask?.value
        pollTask = nil

        if let token = notifyToken {
            DistributedNotificationCenter.default().removeObserver(token)
            notifyToken = nil
        }

        stream?.stop()
        stream = nil
        currentPaths = []
        currentFolders = []

        logger.info("FSEventsCollector stopped")
    }

    /// Re-read watched_folders + restart stream если diff в paths.
    /// Вызывается из Darwin notification listener + poll fallback + tests.
    public func reload() async {
        await rebuildStream()
    }

    // MARK: - Internal

    /// Read enabled folders, canonicalize paths, restart stream если diff.
    /// Идемпотентен — повторный вызов с same paths = no-op (cheap path compare).
    private func rebuildStream() async {
        let folders = (try? database.listWatchedFolders(includingDisabled: false)) ?? []
        let paths =
            folders
            .map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
            .sorted()

        // No diff — keep existing stream.
        if paths == currentPaths {
            currentFolders = folders
            return
        }

        // Tear down existing stream (if any).
        stream?.stop()
        stream = nil

        // No paths — collector idle (UI пустой / все disabled).
        guard !paths.isEmpty else {
            currentPaths = []
            currentFolders = []
            logger.debug("rebuildStream: no enabled folders, idle")
            return
        }

        // Spin up new stream — onEvents hop'ает обратно в actor через Task.
        do {
            let newStream = try FSEventStream(
                paths: paths,
                latency: latencySec
            ) { [weak self] eventPaths, eventFlags in
                guard let self else { return }
                Task { await self.handleBatch(paths: eventPaths, flags: eventFlags) }
            }
            newStream.start()
            stream = newStream
            currentPaths = paths
            currentFolders = folders
            logger.info("rebuildStream: watching \(paths.count, privacy: .public) folder(s)")
        } catch {
            logger.error("rebuildStream failed: \(String(describing: error), privacy: .public)")
            currentPaths = []
            currentFolders = []
        }
    }

    private func runPollLoop() async {
        // Initial half-interval delay чтобы не race'нуть со start'овым rebuild.
        await sleep(seconds: reconfigPollSec / 2)
        while !Task.isCancelled {
            await reload()
            await sleep(seconds: reconfigPollSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        let ns = UInt64(max(0, seconds) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)
    }

    /// FSEvents batch handler — вызывается из FSEventStream callback (через Task).
    /// Идёт через router → батчит RawEvent → atomic write в `events`.
    func handleBatch(paths: [String], flags: [UInt32]) async {
        guard paths.count == flags.count else {
            logger.warning("handleBatch: paths.count != flags.count — dropping batch")
            return
        }
        let now = Date()
        var events: [RawEvent] = []
        for (path, flag) in zip(paths, flags) {
            let result = await router.route(
                path: path,
                flags: flag,
                watchedFolders: currentFolders,
                now: now
            )
            switch result {
            case .event(let raw):
                events.append(raw)
            case .filtered(let reason):
                logger.debug("filtered \(path, privacy: .public): \(reason, privacy: .public)")
            case .unknown:
                continue
            }
        }
        guard !events.isEmpty else { return }
        do {
            try database.writeEventsAndOffset(events, offset: nil)
            logger.info("wrote \(events.count, privacy: .public) content events")
        } catch {
            logger.error("write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
