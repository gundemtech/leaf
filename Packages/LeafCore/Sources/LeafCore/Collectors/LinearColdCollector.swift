import Foundation
import os

/// Phase Track-3 D1 — cold-tier (4am local, daily) Linear collector.
///
/// On each tick:
///  1. Reads integration row; skip if absent.
///  2. Refreshes token.
///  3. Reads 3 prior snapshots from provider_snapshots
///     (linear_custom_views / linear_project_memberships / linear_roadmap_state).
///  4. Calls provider.fetchColdState(accessToken:); maps batch into RawEvent[]:
///     - Heartbeat per (roadmap × project) pair every tick (linear_roadmap_state_observed)
///     - CustomView created/updated/deleted via diff
///     - ProjectMembership added/removed via diff
///  5. Atomic write via Database.writeEventsOffsetsAndSnapshots, advancing
///     `linear:cold:<wid>` offset.lastModifiedMs = nowMs (used as catch-up gate).
public actor LinearColdCollector {
    private let database: Database
    private let provider: any LinearGraphQLProvider
    private let refresher: LinearTokenRefresher
    private let intervalSec: TimeInterval  // not used directly (scheduled externally), retained for parity
    private let logger: Logger

    private var loopTask: Task<Void, Never>?

    public init(
        database: Database,
        provider: any LinearGraphQLProvider,
        refresher: LinearTokenRefresher,
        intervalSec: TimeInterval = 86_400,
        logger: Logger
    ) {
        self.database = database
        self.provider = provider
        self.refresher = refresher
        self.intervalSec = intervalSec
        self.logger = logger
    }

    public func start() {
        // Cold tier is driven by LinearColdScheduler (4am anchor). start()/stop()
        // here exist for symmetry — actual cadence is owned by the scheduler.
        logger.info("LinearColdCollector ready")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        logger.info("LinearColdCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let eventsEmitted: Int
    }

    public struct CustomViewsDiff: Sendable {
        public let created: [LinearCustomViewSnapshot]
        public let updated: [LinearCustomViewSnapshot]
        public let deleted: [LinearCustomViewSnapshot]
    }

    public struct ProjectMembershipsDiff: Sendable {
        public let added: [LinearProjectMembershipSnapshot]
        public let removed: [LinearProjectMembershipSnapshot]
    }

    public static func customViewsDiff(
        prior: [LinearCustomViewSnapshot], current: [LinearCustomViewSnapshot]
    ) -> CustomViewsDiff {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var created: [LinearCustomViewSnapshot] = []
        var updated: [LinearCustomViewSnapshot] = []
        for (id, curr) in currentByID {
            if let p = priorByID[id] {
                if p.name != curr.name || p.updatedAtMs != curr.updatedAtMs {
                    updated.append(curr)
                }
            } else {
                created.append(curr)
            }
        }
        let deleted = priorByID.values.filter { currentByID[$0.id] == nil }
        return CustomViewsDiff(
            created: created.sorted(by: { $0.id < $1.id }),
            updated: updated.sorted(by: { $0.id < $1.id }),
            deleted: deleted.sorted(by: { $0.id < $1.id })
        )
    }

    public static func projectMembershipsDiff(
        prior: [LinearProjectMembershipSnapshot], current: [LinearProjectMembershipSnapshot]
    ) -> ProjectMembershipsDiff {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.projectId, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.projectId, $0) })
        let added = currentByID.values.filter { priorByID[$0.projectId] == nil }
        let removed = priorByID.values.filter { currentByID[$0.projectId] == nil }
        return ProjectMembershipsDiff(
            added: added.sorted(by: { $0.projectId < $1.projectId }),
            removed: removed.sorted(by: { $0.projectId < $1.projectId })
        )
    }

    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .linear)
        } catch {
            logger.error("cold readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        guard record != nil else { return TickResult(skipped: true, eventsEmitted: 0) }

        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch {
            logger.error("cold refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }

        let workspaceID = refreshed.workspaceID
        let coldSource = "linear:cold:\(workspaceID)"

        // Read 3 prior snapshots.
        let priorViews: [LinearCustomViewSnapshot] = readPriorViews()
        let priorMembers: [LinearProjectMembershipSnapshot] = readPriorMemberships()

        let batch: LinearColdBatch
        do {
            batch = try await provider.fetchColdState(accessToken: refreshed.accessToken)
        } catch {
            logger.error("fetchColdState failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }

        var events: [RawEvent] = []
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // Roadmap heartbeat — emit per (roadmap × project) pair every tick.
        for r in batch.roadmaps {
            for p in r.projects {
                events.append(Self.makeRoadmapStateObservedEvent(roadmap: r, project: p, observedAtMs: nowMs))
            }
        }

        // CustomView diff. Bootstrap path: prior empty AND no snapshot row → skip emissions.
        let priorViewsSnapshotExists = priorViewsSnapshotPresent()
        if priorViewsSnapshotExists {
            let d = Self.customViewsDiff(prior: priorViews, current: batch.customViews)
            events.append(contentsOf: d.created.map { Self.makeCustomViewCreatedEvent($0, observedAtMs: nowMs) })
            events.append(contentsOf: d.updated.map { Self.makeCustomViewUpdatedEvent($0, observedAtMs: nowMs) })
            events.append(contentsOf: d.deleted.map { Self.makeCustomViewDeletedEvent($0, observedAtMs: nowMs) })
        }

        // ProjectMembership diff. Same bootstrap discipline.
        let priorMembersSnapshotExists = priorMembersSnapshotPresent()
        if priorMembersSnapshotExists {
            let d = Self.projectMembershipsDiff(prior: priorMembers, current: batch.projectMemberships)
            events.append(contentsOf: d.added.map { Self.makeProjectMembershipAddedEvent($0, observedAtMs: nowMs) })
            events.append(contentsOf: d.removed.map { Self.makeProjectMembershipRemovedEvent($0, observedAtMs: nowMs) })
        }

        // Build 3 snapshots (always overwrite — roadmap snapshot is forward-compat substrate).
        var snapshots: [ProviderSnapshot] = []
        snapshots.append(encodeViewsSnapshot(batch.customViews, capturedAtMs: nowMs))
        snapshots.append(encodeMembershipsSnapshot(batch.projectMemberships, capturedAtMs: nowMs))
        snapshots.append(encodeRoadmapSnapshot(batch.roadmaps, capturedAtMs: nowMs))

        // Cold offset = nowMs (catch-up gate).
        let coldOffset = CollectorOffset(
            collectorID: CollectorID.linearColdPolling, sourceID: coldSource,
            byteOffset: 0, inode: nil, size: 0, lastModifiedMs: nowMs, updatedMs: nowMs
        )

        do {
            try database.writeEventsOffsetsAndSnapshots(events: events, offsets: [coldOffset], snapshots: snapshots)
        } catch {
            logger.error("cold persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }
        if !events.isEmpty {
            logger.info("cold tick wrote \(events.count, privacy: .public) events")
        }
        return TickResult(skipped: false, eventsEmitted: events.count)
    }

    // MARK: - Snapshot read / encode helpers

    private struct ViewsSnapshotJSON: Codable {
        struct V: Codable {
            let id: String
            let name: String
            let teamId: String?
            let updatedAtMs: Int64
        }
        let views: [V]
    }
    private struct MembershipsSnapshotJSON: Codable {
        struct M: Codable {
            let projectId: String
            let projectName: String
        }
        let memberships: [M]
    }
    private struct RoadmapSnapshotJSON: Codable {
        struct P: Codable {
            let roadmapId: String
            let projectId: String
            let projectName: String
            let stateEnum: String
        }
        let pairs: [P]
    }

    private func readPriorViews() -> [LinearCustomViewSnapshot] {
        guard let snap = readSnapshot(Schema.ProviderSnapshotKinds.linearCustomViews) else { return [] }
        guard let parsed = try? JSONDecoder().decode(ViewsSnapshotJSON.self, from: Data(snap.snapshotJSON.utf8)) else {
            return []
        }
        return parsed.views.map {
            LinearCustomViewSnapshot(id: $0.id, name: $0.name, teamId: $0.teamId, updatedAtMs: $0.updatedAtMs)
        }
    }

    private func priorViewsSnapshotPresent() -> Bool {
        readSnapshot(Schema.ProviderSnapshotKinds.linearCustomViews) != nil
    }

    private func readPriorMemberships() -> [LinearProjectMembershipSnapshot] {
        guard let snap = readSnapshot(Schema.ProviderSnapshotKinds.linearProjectMemberships) else { return [] }
        guard let parsed = try? JSONDecoder().decode(MembershipsSnapshotJSON.self, from: Data(snap.snapshotJSON.utf8))
        else { return [] }
        return parsed.memberships.map {
            LinearProjectMembershipSnapshot(projectId: $0.projectId, projectName: $0.projectName)
        }
    }

    private func priorMembersSnapshotPresent() -> Bool {
        readSnapshot(Schema.ProviderSnapshotKinds.linearProjectMemberships) != nil
    }

    private func readSnapshot(_ kind: String) -> ProviderSnapshot? {
        try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(provider: "linear", snapshotKind: kind, in: raw)
        }
    }

    private func encodeViewsSnapshot(_ views: [LinearCustomViewSnapshot], capturedAtMs: Int64) -> ProviderSnapshot {
        let payload = ViewsSnapshotJSON(
            views: views.map { .init(id: $0.id, name: $0.name, teamId: $0.teamId, updatedAtMs: $0.updatedAtMs) })
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"views\":[]}"
        return ProviderSnapshot(
            provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearCustomViews, snapshotJSON: s,
            capturedAtMs: capturedAtMs)
    }

    private func encodeMembershipsSnapshot(
        _ ms: [LinearProjectMembershipSnapshot], capturedAtMs: Int64
    ) -> ProviderSnapshot {
        let payload = MembershipsSnapshotJSON(
            memberships: ms.map { .init(projectId: $0.projectId, projectName: $0.projectName) })
        let s =
            (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"memberships\":[]}"
        return ProviderSnapshot(
            provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearProjectMemberships, snapshotJSON: s,
            capturedAtMs: capturedAtMs)
    }

    private func encodeRoadmapSnapshot(_ rs: [LinearRoadmapSnapshot], capturedAtMs: Int64) -> ProviderSnapshot {
        var pairs: [RoadmapSnapshotJSON.P] = []
        for r in rs {
            for p in r.projects {
                pairs.append(
                    .init(roadmapId: r.id, projectId: p.projectId, projectName: p.projectName, stateEnum: p.stateEnum))
            }
        }
        let s =
            (try? JSONEncoder().encode(RoadmapSnapshotJSON(pairs: pairs))).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"pairs\":[]}"
        return ProviderSnapshot(
            provider: "linear", snapshotKind: Schema.ProviderSnapshotKinds.linearRoadmapState, snapshotJSON: s,
            capturedAtMs: capturedAtMs)
    }

    // MARK: - Event builders

    static func makeRoadmapStateObservedEvent(
        roadmap: LinearRoadmapSnapshot, project: LinearRoadmapProjectSnapshot, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_roadmap_state_observed",
            Schema.EventPayloadKeys.roadmapId: roadmap.id,
            Schema.EventPayloadKeys.projectId: project.projectId,
            Schema.EventPayloadKeys.projectName: project.projectName,
            Schema.EventPayloadKeys.stateEnum: project.stateEnum,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let n = roadmap.name { payload[Schema.EventPayloadKeys.roadmapName] = n }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    static func makeCustomViewCreatedEvent(_ v: LinearCustomViewSnapshot, observedAtMs: Int64) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_custom_view_created",
            Schema.EventPayloadKeys.viewId: v.id,
            Schema.EventPayloadKeys.viewName: v.name,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let t = v.teamId { payload[Schema.EventPayloadKeys.teamId] = t }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload)
    }

    static func makeCustomViewUpdatedEvent(_ v: LinearCustomViewSnapshot, observedAtMs: Int64) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_custom_view_updated",
            Schema.EventPayloadKeys.viewId: v.id,
            Schema.EventPayloadKeys.viewName: v.name,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let t = v.teamId { payload[Schema.EventPayloadKeys.teamId] = t }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload)
    }

    static func makeCustomViewDeletedEvent(_ v: LinearCustomViewSnapshot, observedAtMs: Int64) -> RawEvent {
        var payload: [String: String] = [
            "source": "linear",
            "event_kind": "linear_custom_view_deleted",
            Schema.EventPayloadKeys.viewId: v.id,
            Schema.EventPayloadKeys.viewName: v.name,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
        ]
        if let t = v.teamId { payload[Schema.EventPayloadKeys.teamId] = t }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload)
    }

    static func makeProjectMembershipAddedEvent(_ m: LinearProjectMembershipSnapshot, observedAtMs: Int64) -> RawEvent {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_project_membership_added",
                Schema.EventPayloadKeys.projectId: m.projectId,
                Schema.EventPayloadKeys.projectName: m.projectName,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ])
    }

    static func makeProjectMembershipRemovedEvent(_ m: LinearProjectMembershipSnapshot, observedAtMs: Int64) -> RawEvent
    {
        RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil,
            payload: [
                "source": "linear",
                "event_kind": "linear_project_membership_removed",
                Schema.EventPayloadKeys.projectId: m.projectId,
                Schema.EventPayloadKeys.projectName: m.projectName,
                Schema.EventPayloadKeys.observedAtMs: String(observedAtMs),
            ])
    }
}
