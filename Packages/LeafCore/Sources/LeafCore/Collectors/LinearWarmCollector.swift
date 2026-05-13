import Foundation
import os

/// Phase Track-3 D1 — warm-tier (15m) Linear collector.
///
/// On each tick:
///  1. Reads integration row (provider=.linear); skip if absent.
///  2. Refreshes token via LinearTokenRefresher (same path as hot LinearCollector).
///  3. Reads notification + cycle cursors from collector_offsets
///     (sourceID `linear:notifications:<wid>` / `linear:cycles:<wid>`) and the
///     prior linear_subscribed_issues snapshot from provider_snapshots.
///  4. Calls provider.fetchWarmState(accessToken:cursors:); maps the batch into
///     RawEvent[] (3 notification flavors + 2 cycle flavors + subscription
///     added/removed via set-diff).
///  5. Atomic write via Database.writeEventsOffsetsAndSnapshots.
///
/// Bootstrap behavior (no prior snapshot): emits zero subscription events on
/// the first tick — just writes the current snapshot. Day-2 diff yields normal
/// added/removed events.
public actor LinearWarmCollector {
    private let database: Database
    private let provider: any LinearGraphQLProvider
    private let refresher: LinearTokenRefresher
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger

    private var loopTask: Task<Void, Never>?

    public init(
        database: Database,
        provider: any LinearGraphQLProvider,
        refresher: LinearTokenRefresher,
        intervalSec: TimeInterval,
        backfillWindowDays: Int,
        logger: Logger
    ) {
        self.database = database
        self.provider = provider
        self.refresher = refresher
        self.intervalSec = intervalSec
        self.backfillWindowDays = backfillWindowDays
        self.logger = logger
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.runLoop() }
        logger.info("LinearWarmCollector started (interval=\(self.intervalSec, privacy: .public)s)")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        logger.info("LinearWarmCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let eventsEmitted: Int
        public init(skipped: Bool, eventsEmitted: Int) {
            self.skipped = skipped
            self.eventsEmitted = eventsEmitted
        }
    }

    /// Set difference helper exposed for unit tests.
    public static func subscribedIssuesDiff(prior: [String], current: [String]) -> (added: [String], removed: [String]) {
        let priorSet = Set(prior)
        let currentSet = Set(current)
        let added = Array(currentSet.subtracting(priorSet)).sorted()
        let removed = Array(priorSet.subtracting(currentSet)).sorted()
        return (added, removed)
    }

    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .linear)
        } catch {
            logger.error("warm readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        guard record != nil else { return TickResult(skipped: true, eventsEmitted: 0) }

        // 2. Token refresh.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch LinearTokenRefresherError.refreshDenied(let msg) {
            logger.warning("warm refresh denied: \(msg, privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        } catch {
            logger.error("warm refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }

        let workspaceID = refreshed.workspaceID
        let notifSource = "linear:notifications:\(workspaceID)"
        let cyclesSource = "linear:cycles:\(workspaceID)"

        // 3. Cursors + snapshot.
        let notifCursor = (try? database.readOffset(collectorID: CollectorID.linearWarmPolling, sourceID: notifSource))?.lastModifiedMs
        let cyclesCursor = (try? database.readOffset(collectorID: CollectorID.linearWarmPolling, sourceID: cyclesSource))?.lastModifiedMs
        let priorSnapshot: ProviderSnapshot? = {
            do {
                return try database.readSQL { rawDB in
                    try ProviderSnapshotsStore.read(
                        provider: "linear",
                        snapshotKind: Schema.ProviderSnapshotKinds.linearSubscribedIssues,
                        in: rawDB
                    )
                }
            } catch {
                logger.error("warm snapshot read failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }()

        // 4. Fetch.
        let cursors = LinearWarmCursors(notificationsSince: notifCursor, cyclesSince: cyclesCursor)
        let batch: LinearWarmBatch
        do {
            batch = try await provider.fetchWarmState(accessToken: refreshed.accessToken, cursors: cursors)
        } catch {
            logger.error("fetchWarmState failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }

        // 5. Map to events.
        var events: [RawEvent] = []
        let prevNotifCursor: Int64 = notifCursor ?? 0
        for n in batch.notifications {
            if n.createdAtMs > prevNotifCursor {
                events.append(Self.makeNotificationReceivedEvent(n))
            }
            if let readMs = n.readAtMs, readMs > prevNotifCursor {
                events.append(Self.makeNotificationReadEvent(n, readMs: readMs))
            }
            if let archMs = n.archivedAtMs, archMs > prevNotifCursor {
                events.append(Self.makeNotificationArchivedEvent(n, archivedMs: archMs))
            }
        }
        events.append(contentsOf: batch.cyclesStarted.map(Self.makeCycleStartedEvent))
        events.append(contentsOf: batch.cyclesCompleted.map(Self.makeCycleCompletedEvent))

        // Subscribed issues diff.
        let currentIDs = batch.subscribedIssueIds.map { $0.id }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var subscribedSnapshotChanged = false
        if let prior = priorSnapshot,
           let parsed = try? JSONDecoder().decode(SubscribedSnapshotJSON.self, from: Data(prior.snapshotJSON.utf8)) {
            let diff = Self.subscribedIssuesDiff(prior: parsed.ids, current: currentIDs)
            for id in diff.added {
                let identifier = batch.subscribedIssueIds.first(where: { $0.id == id })?.identifier ?? id
                events.append(Self.makeSubscriptionAddedEvent(issueId: id, issueIdentifier: identifier, observedAtMs: nowMs))
            }
            for id in diff.removed {
                events.append(Self.makeSubscriptionRemovedEvent(issueId: id, issueIdentifier: id, observedAtMs: nowMs))
            }
            subscribedSnapshotChanged = !diff.added.isEmpty || !diff.removed.isEmpty
        } else {
            // Bootstrap: write the snapshot, emit nothing.
            subscribedSnapshotChanged = true
        }

        // 6. Build offsets + snapshot.
        var offsets: [CollectorOffset] = []
        if let cur = batch.notificationCursorMs {
            offsets.append(CollectorOffset(
                collectorID: CollectorID.linearWarmPolling, sourceID: notifSource,
                byteOffset: 0, inode: nil, size: 0, lastModifiedMs: cur, updatedMs: nowMs))
        }
        if let cur = batch.cyclesCursorMs {
            offsets.append(CollectorOffset(
                collectorID: CollectorID.linearWarmPolling, sourceID: cyclesSource,
                byteOffset: 0, inode: nil, size: 0, lastModifiedMs: cur, updatedMs: nowMs))
        }

        var snapshots: [ProviderSnapshot] = []
        if subscribedSnapshotChanged {
            let encoded = (try? JSONEncoder().encode(SubscribedSnapshotJSON(ids: currentIDs)))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ids\":[]}"
            snapshots.append(ProviderSnapshot(
                provider: "linear",
                snapshotKind: Schema.ProviderSnapshotKinds.linearSubscribedIssues,
                snapshotJSON: encoded,
                capturedAtMs: nowMs
            ))
        }

        // 7. Atomic write.
        do {
            try database.writeEventsOffsetsAndSnapshots(events: events, offsets: offsets, snapshots: snapshots)
        } catch {
            logger.error("warm persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }
        if !events.isEmpty {
            logger.info("warm tick wrote \(events.count, privacy: .public) events")
        }
        return TickResult(skipped: false, eventsEmitted: events.count)
    }

    private func runLoop() async {
        // Stagger by half the interval to avoid colliding with the hot tier
        // tick at exact 5m boundaries.
        try? await Task.sleep(nanoseconds: UInt64(max(0, intervalSec / 2) * 1_000_000_000))
        while !Task.isCancelled {
            _ = await performTick()
            try? await Task.sleep(nanoseconds: UInt64(max(0, intervalSec) * 1_000_000_000))
        }
    }

    // MARK: - JSON snapshot shape

    private struct SubscribedSnapshotJSON: Codable {
        let ids: [String]
    }

    // MARK: - Event builders

    static func makeNotificationReceivedEvent(_ n: LinearNotificationSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_notification_received",
            Schema.EventPayloadKeys.notificationId: n.id,
            Schema.EventPayloadKeys.notificationKind: n.kind,
            Schema.EventPayloadKeys.notificationTitle: n.title,
            // Mirror title under canonical `body` key so EventsFullTextStore picks it up.
            Schema.EventPayloadKeys.body: n.title,
            Schema.EventPayloadKeys.receivedAtMs: String(n.createdAtMs)
        ]
        if let id = n.issueId { payload[Schema.EventPayloadKeys.issueId] = id }
        if let ident = n.issueIdentifier { payload[Schema.EventPayloadKeys.issueIdentifier] = ident }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(n.createdAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    static func makeNotificationReadEvent(_ n: LinearNotificationSnapshot, readMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(readMs) / 1000.0),
            signalType: .context, bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_notification_read",
                Schema.EventPayloadKeys.notificationId: n.id,
                Schema.EventPayloadKeys.readAtMs: String(readMs)
            ]
        )
    }

    static func makeNotificationArchivedEvent(_ n: LinearNotificationSnapshot, archivedMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(archivedMs) / 1000.0),
            signalType: .context, bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_notification_archived",
                Schema.EventPayloadKeys.notificationId: n.id,
                Schema.EventPayloadKeys.archivedAtMs: String(archivedMs)
            ]
        )
    }

    static func makeCycleStartedEvent(_ c: LinearCycleLifecycleSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_cycle_started",
            Schema.EventPayloadKeys.cycleId: c.id,
            Schema.EventPayloadKeys.cycleNumber: String(c.number),
            Schema.EventPayloadKeys.teamId: c.teamId,
            Schema.EventPayloadKeys.startedAtMs: String(c.startsAtMs),
            Schema.EventPayloadKeys.endsAtMs: String(c.endsAtMs)
        ]
        if let n = c.name { payload[Schema.EventPayloadKeys.cycleName] = n }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(c.startsAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    static func makeCycleCompletedEvent(_ c: LinearCycleLifecycleSnapshot) -> RawEvent {
        let completedMs = c.completedAtMs ?? c.endsAtMs
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_cycle_completed",
            Schema.EventPayloadKeys.cycleId: c.id,
            Schema.EventPayloadKeys.cycleNumber: String(c.number),
            Schema.EventPayloadKeys.teamId: c.teamId,
            Schema.EventPayloadKeys.completedAtMs: String(completedMs)
        ]
        if let p = c.progress { payload[Schema.EventPayloadKeys.progress] = String(p) }
        if let ic = c.issuesCompletedCount { payload[Schema.EventPayloadKeys.issuesCompletedCount] = String(ic) }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(completedMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    static func makeSubscriptionAddedEvent(issueId: String, issueIdentifier: String, observedAtMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_subscription_added",
                Schema.EventPayloadKeys.issueId: issueId,
                Schema.EventPayloadKeys.issueIdentifier: issueIdentifier,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
            ]
        )
    }

    static func makeSubscriptionRemovedEvent(issueId: String, issueIdentifier: String, observedAtMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_subscription_removed",
                Schema.EventPayloadKeys.issueId: issueId,
                Schema.EventPayloadKeys.issueIdentifier: issueIdentifier,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
            ]
        )
    }
}
