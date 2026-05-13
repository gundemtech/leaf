//
//  GitHubWarmCollector.swift
//  LeafCore
//
//  Phase Track-3 D2 — GitHub warm-tier (15m) collector. Mirrors
//  LinearWarmCollector shape (actor + start/stop loop + performTick + atomic
//  write entry point). Five endpoint groups, 13 event_kinds:
//   1. fetchProjectsV2State → card_moved / iteration_changed / field_updated
//      (gated on `read:project` scope, bounded fan-out cap projectsV2TopN)
//   2. fetchGists → created / updated / deleted (singleton snapshot diff)
//   3. fetchRepoInvitations → received / accepted (invitation_id diff)
//   4. fetchCodespaces → created / started / stopped / deleted (name-keyed,
//      state transitions for Available / Shutdown only)
//   5. fetchIssueReactions → reaction_received (per-emoji positive delta;
//      bounded fan-out over `Database.queryRecentViewerAuthoredIssues`, cap
//      `issueReactionsTopK`, 7-day lookback)
//
//  Bootstrap discipline (mirror Linear D1): first tick with no prior snapshot
//  emits zero diff events but writes the new snapshot — Day-2 tick produces
//  the normal added/removed/updated stream.
//
//  Atomic write through `Database.writeEventsOffsetsAndSnapshots`. Single
//  offset row `github:warm:<login>` whose `lastModifiedMs` is the tick wall
//  clock (used by `GitHubWarmScheduler` catch-up gate in Task 9).
//
//  Privacy (ADR-010 §6): event payloads carry public-safe metadata only.
//  Gist description is body-bearing — routed under `Schema.EventPayloadKeys.body`
//  for FTS pickup (body kind `gh_gist_description` wired in Task 25).
//  Repo invitations, project titles, codespace names are public-safe.
//

import Foundation
import os

public actor GitHubWarmCollector {
    public static let projectsV2TopN = 10
    public static let issueReactionsTopK = 10
    public static let issueReactionsLookbackDays = 7

    private let database: Database
    private let provider: any GitHubAPIProvider
    private let refresher: GitHubTokenRefresher
    private let scopeService: any GitHubScopesChecking
    private let intervalSec: TimeInterval
    private let logger: Logger

    private var loopTask: Task<Void, Never>?

    public init(
        database: Database,
        provider: any GitHubAPIProvider,
        refresher: GitHubTokenRefresher,
        scopeService: any GitHubScopesChecking,
        intervalSec: TimeInterval,
        logger: Logger
    ) {
        self.database = database
        self.provider = provider
        self.refresher = refresher
        self.scopeService = scopeService
        self.intervalSec = intervalSec
        self.logger = logger
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.runLoop() }
        logger.info("GitHubWarmCollector started (interval=\(self.intervalSec, privacy: .public)s)")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        logger.info("GitHubWarmCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let eventsEmitted: Int
        public init(skipped: Bool, eventsEmitted: Int) {
            self.skipped = skipped
            self.eventsEmitted = eventsEmitted
        }
    }

    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .github)
        } catch {
            logger.error("warm readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        guard record != nil else { return TickResult(skipped: true, eventsEmitted: 0) }

        // 2. Token refresh.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch GitHubTokenRefresherError.refreshDenied(let msg) {
            logger.warning("warm refresh denied: \(msg, privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        } catch {
            logger.error("warm refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }

        let login = refreshed.workspaceName
        let sourceID = "github:warm:\(login)"
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        var events: [RawEvent] = []
        var snapshots: [ProviderSnapshot] = []

        // --- 3a. ProjectsV2 (scope-gated) --------------------------------------
        if await scopeService.has("read:project") {
            do {
                let snap = try await provider.fetchProjectsV2State(
                    accessToken: refreshed.accessToken,
                    login: login,
                    topN: Self.projectsV2TopN
                )
                await ingestProjectsV2(
                    snap, nowMs: nowMs, events: &events, snapshots: &snapshots
                )
            } catch {
                logger.error("fetchProjectsV2State failed: \(String(describing: error), privacy: .public)")
            }
        }

        // --- 3b. Gists (singleton snapshot) ------------------------------------
        do {
            let current = try await provider.fetchGists(
                accessToken: refreshed.accessToken, login: login
            )
            ingestGists(current, nowMs: nowMs, events: &events, snapshots: &snapshots)
        } catch {
            logger.error("fetchGists failed: \(String(describing: error), privacy: .public)")
        }

        // --- 3c. Repo invitations ----------------------------------------------
        do {
            let current = try await provider.fetchRepoInvitations(
                accessToken: refreshed.accessToken
            )
            ingestInvitations(current, nowMs: nowMs, events: &events, snapshots: &snapshots)
        } catch {
            logger.error("fetchRepoInvitations failed: \(String(describing: error), privacy: .public)")
        }

        // --- 3d. Codespaces ----------------------------------------------------
        do {
            let current = try await provider.fetchCodespaces(
                accessToken: refreshed.accessToken
            )
            ingestCodespaces(current, nowMs: nowMs, events: &events, snapshots: &snapshots)
        } catch {
            logger.error("fetchCodespaces failed: \(String(describing: error), privacy: .public)")
        }

        // --- 3e. Issue reactions (bounded fan-out) -----------------------------
        let lookbackMs = Int64(Self.issueReactionsLookbackDays) * 86_400_000
        let recentIssues: [String]
        do {
            recentIssues = try database.queryRecentViewerAuthoredIssues(
                sinceMs: nowMs - lookbackMs,
                limit: Self.issueReactionsTopK
            )
        } catch {
            logger.error("queryRecentViewerAuthoredIssues failed: \(String(describing: error), privacy: .public)")
            recentIssues = []
        }
        for ref in recentIssues {
            guard let parsed = Self.parseIssueRef(ref) else { continue }
            do {
                let snap = try await provider.fetchIssueReactions(
                    accessToken: refreshed.accessToken,
                    owner: parsed.owner, repo: parsed.repo, issueNumber: parsed.number
                )
                ingestIssueReactions(snap, nowMs: nowMs, events: &events, snapshots: &snapshots)
            } catch {
                logger.error("fetchIssueReactions \(ref, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }

        // --- 4. Build offset row -----------------------------------------------
        let offset = CollectorOffset(
            collectorID: CollectorID.githubWarmPolling,
            sourceID: sourceID,
            byteOffset: 0, inode: nil, size: 0,
            lastModifiedMs: nowMs, updatedMs: nowMs
        )

        // --- 5. Atomic write ----------------------------------------------------
        do {
            try database.writeEventsOffsetsAndSnapshots(
                events: events, offsets: [offset], snapshots: snapshots
            )
        } catch {
            logger.error("warm persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }
        if !events.isEmpty {
            logger.info("github warm tick wrote \(events.count, privacy: .public) events")
        }
        return TickResult(skipped: false, eventsEmitted: events.count)
    }

    private func runLoop() async {
        // Stagger by half the interval — mirrors LinearWarmCollector pattern.
        try? await Task.sleep(nanoseconds: UInt64(max(0, intervalSec / 2) * 1_000_000_000))
        while !Task.isCancelled {
            _ = await performTick()
            try? await Task.sleep(nanoseconds: UInt64(max(0, intervalSec) * 1_000_000_000))
        }
    }

    // MARK: - Endpoint ingestion (mutates events + snapshots arrays)

    private func ingestProjectsV2(
        _ snap: GitHubProjectsV2Snapshot,
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) async {
        for project in snap.projects {
            let kind = Schema.ProviderSnapshotKinds.githubProjectV2ItemsPrefix + project.projectID
            let prior: [GitHubProjectV2ItemSnapshot] = readSnapshotArray(kind: kind)
            let priorPresent = snapshotRowPresent(kind: kind)
            if priorPresent {
                let (cardMoved, iter, fields) = Self.projectsV2Diff(
                    prior: prior, current: project.items
                )
                for row in cardMoved {
                    events.append(Self.makeProjectCardMovedEvent(
                        itemID: row.0, projectID: row.1, oldStatus: row.2, newStatus: row.3,
                        observedAtMs: nowMs
                    ))
                }
                for row in iter {
                    events.append(Self.makeProjectIterationChangedEvent(
                        itemID: row.0, projectID: row.1, oldIteration: row.2, newIteration: row.3,
                        observedAtMs: nowMs
                    ))
                }
                for row in fields {
                    events.append(Self.makeProjectFieldUpdatedEvent(
                        itemID: row.0, projectID: row.1, fieldName: row.2,
                        oldValue: row.3, newValue: row.4, observedAtMs: nowMs
                    ))
                }
            }
            // Always write the current snapshot (bootstrap discipline: first
            // tick writes only).
            snapshots.append(makeSnapshot(kind: kind, encoding: project.items, nowMs: nowMs))
        }
    }

    private func ingestGists(
        _ current: [GitHubGistSnapshot],
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind = Schema.ProviderSnapshotKinds.githubGists
        let prior: [GitHubGistSnapshot] = readSnapshotArray(kind: kind)
        if snapshotRowPresent(kind: kind) {
            let (created, updated, deleted) = Self.gistsDiff(prior: prior, current: current)
            events.append(contentsOf: created.map { Self.makeGistCreatedEvent($0, observedAtMs: nowMs) })
            events.append(contentsOf: updated.map { Self.makeGistUpdatedEvent($0, observedAtMs: nowMs) })
            events.append(contentsOf: deleted.map { Self.makeGistDeletedEvent($0, observedAtMs: nowMs) })
        }
        snapshots.append(makeSnapshot(kind: kind, encoding: current, nowMs: nowMs))
    }

    private func ingestInvitations(
        _ current: [GitHubRepoInvitationSnapshot],
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind = Schema.ProviderSnapshotKinds.githubRepoInvitations
        let prior: [GitHubRepoInvitationSnapshot] = readSnapshotArray(kind: kind)
        if snapshotRowPresent(kind: kind) {
            let (received, accepted) = Self.invitationsDiff(prior: prior, current: current)
            events.append(contentsOf: received.map {
                Self.makeRepoInvitationReceivedEvent($0, observedAtMs: nowMs)
            })
            events.append(contentsOf: accepted.map {
                Self.makeRepoInvitationAcceptedEvent($0, observedAtMs: nowMs)
            })
        }
        snapshots.append(makeSnapshot(kind: kind, encoding: current, nowMs: nowMs))
    }

    private func ingestCodespaces(
        _ current: [GitHubCodespaceSnapshot],
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind = Schema.ProviderSnapshotKinds.githubCodespaces
        let prior: [GitHubCodespaceSnapshot] = readSnapshotArray(kind: kind)
        if snapshotRowPresent(kind: kind) {
            let (created, started, stopped, deleted) = Self.codespacesDiff(prior: prior, current: current)
            events.append(contentsOf: created.map {
                Self.makeCodespaceCreatedEvent($0, observedAtMs: nowMs)
            })
            events.append(contentsOf: started.map {
                Self.makeCodespaceStartedEvent($0, observedAtMs: nowMs)
            })
            events.append(contentsOf: stopped.map {
                Self.makeCodespaceStoppedEvent($0, observedAtMs: nowMs)
            })
            events.append(contentsOf: deleted.map {
                Self.makeCodespaceDeletedEvent($0, observedAtMs: nowMs)
            })
        }
        snapshots.append(makeSnapshot(kind: kind, encoding: current, nowMs: nowMs))
    }

    private func ingestIssueReactions(
        _ current: GitHubIssueReactionsSnapshot,
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind = Schema.ProviderSnapshotKinds.githubIssueReactionsPrefix
            + "\(current.owner)/\(current.repo)#\(current.issueNumber)"
        let prior: GitHubIssueReactionsSnapshot = readSnapshotValue(kind: kind)
            ?? .empty(owner: current.owner, repo: current.repo,
                      issueNumber: current.issueNumber, nowMs: 0)
        if snapshotRowPresent(kind: kind) {
            let deltas = Self.reactionsDiff(prior: prior, current: current)
            for delta in deltas where delta.newCount > delta.oldCount {
                events.append(Self.makeIssueReactionReceivedEvent(
                    current, emoji: delta.emoji,
                    delta: delta.newCount - delta.oldCount,
                    observedAtMs: nowMs
                ))
            }
        }
        snapshots.append(makeSnapshot(kind: kind, encoding: current, nowMs: nowMs))
    }

    // MARK: - Snapshot helpers

    private func snapshotRowPresent(kind: String) -> Bool {
        do {
            return try database.readSQL { raw in
                try ProviderSnapshotsStore.read(
                    provider: "github", snapshotKind: kind, in: raw
                ) != nil
            }
        } catch {
            return false
        }
    }

    private func readSnapshotArray<T: Decodable>(kind: String) -> [T] {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "github", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: Data(s.snapshotJSON.utf8))) ?? []
    }

    private func readSnapshotValue<T: Decodable>(kind: String) -> T? {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "github", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.snapshotJSON.utf8))
    }

    private func makeSnapshot<T: Encodable>(kind: String, encoding value: T, nowMs: Int64) -> ProviderSnapshot {
        let json: String
        if let data = try? JSONEncoder().encode(value),
           let s = String(data: data, encoding: .utf8) {
            json = s
        } else {
            json = "[]"
        }
        return ProviderSnapshot(
            provider: "github", snapshotKind: kind,
            snapshotJSON: json, capturedAtMs: nowMs
        )
    }

    // MARK: - Issue-ref parsing

    static func parseIssueRef(_ ref: String) -> (owner: String, repo: String, number: Int)? {
        // Expected form: "owner/repo#NN"
        guard let hashIdx = ref.firstIndex(of: "#") else { return nil }
        let repoPart = ref[..<hashIdx]
        let numberPart = ref[ref.index(after: hashIdx)...]
        let slashes = repoPart.split(separator: "/", maxSplits: 1)
        guard slashes.count == 2, let number = Int(numberPart) else { return nil }
        return (String(slashes[0]), String(slashes[1]), number)
    }

    // MARK: - Diff helpers

    /// projectsV2Diff lives at the top of this file (Task 7 shipped it as the
    /// pure helper consumed by performTick). The doc comment + impl remain
    /// untouched — they document the bootstrap discipline + sort order
    /// contract that tests exercise.
    public static func projectsV2Diff(
        prior: [GitHubProjectV2ItemSnapshot],
        current: [GitHubProjectV2ItemSnapshot]
    ) -> (cardMoved: [(String, String, String?, String?)],
          iterationChanged: [(String, String, String?, String?)],
          fieldUpdated: [(String, String, String, String?, String?)]) {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.itemID, $0) })
        var cardMoved: [(String, String, String?, String?)] = []
        var iter: [(String, String, String?, String?)] = []
        var fields: [(String, String, String, String?, String?)] = []
        for curr in current {
            guard let p = priorByID[curr.itemID] else { continue }
            if p.status != curr.status {
                cardMoved.append((curr.itemID, curr.projectID, p.status, curr.status))
            }
            if p.iterationID != curr.iterationID {
                iter.append((curr.itemID, curr.projectID, p.iterationID, curr.iterationID))
            }
            let allFieldNames = Set(p.fieldValues.keys).union(curr.fieldValues.keys)
            for name in allFieldNames.sorted() {
                let oldV = p.fieldValues[name]
                let newV = curr.fieldValues[name]
                if oldV != newV {
                    fields.append((curr.itemID, curr.projectID, name, oldV, newV))
                }
            }
        }
        return (cardMoved.sorted(by: { $0.0 < $1.0 }),
                iter.sorted(by: { $0.0 < $1.0 }),
                fields.sorted(by: { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }))
    }

    /// Gist diff partitions current snapshot vs prior into create / update /
    /// delete buckets, keyed by `gistID`. Update detection uses `updatedAtMs`
    /// strict inequality — descriptions changing without timestamp bump are
    /// trusted to not represent a real edit.
    public static func gistsDiff(
        prior: [GitHubGistSnapshot],
        current: [GitHubGistSnapshot]
    ) -> (created: [GitHubGistSnapshot], updated: [GitHubGistSnapshot], deleted: [GitHubGistSnapshot]) {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.gistID, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.gistID, $0) })
        var created: [GitHubGistSnapshot] = []
        var updated: [GitHubGistSnapshot] = []
        var deleted: [GitHubGistSnapshot] = []
        for c in current {
            if let p = priorByID[c.gistID] {
                if p.updatedAtMs != c.updatedAtMs {
                    updated.append(c)
                }
            } else {
                created.append(c)
            }
        }
        for p in prior where currentByID[p.gistID] == nil {
            deleted.append(p)
        }
        return (
            created.sorted(by: { $0.gistID < $1.gistID }),
            updated.sorted(by: { $0.gistID < $1.gistID }),
            deleted.sorted(by: { $0.gistID < $1.gistID })
        )
    }

    /// Invitation diff: received = present in current but not prior; accepted =
    /// present in prior but absent from current (treated as accepted/cleared;
    /// explicit decline distinction lives in cold-tier audit log if surfaced).
    public static func invitationsDiff(
        prior: [GitHubRepoInvitationSnapshot],
        current: [GitHubRepoInvitationSnapshot]
    ) -> (received: [GitHubRepoInvitationSnapshot], accepted: [GitHubRepoInvitationSnapshot]) {
        let priorByID = Dictionary(uniqueKeysWithValues: prior.map { ($0.invitationID, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.invitationID, $0) })
        let received = current
            .filter { priorByID[$0.invitationID] == nil }
            .sorted(by: { $0.invitationID < $1.invitationID })
        let accepted = prior
            .filter { currentByID[$0.invitationID] == nil }
            .sorted(by: { $0.invitationID < $1.invitationID })
        return (received, accepted)
    }

    /// Codespace diff: created = new codespace name; started = state
    /// transitioned to `Available`; stopped = transitioned to `Shutdown`;
    /// deleted = name absent from current. Transient states (Provisioning /
    /// Queued / Building / Starting / etc) emit nothing.
    public static func codespacesDiff(
        prior: [GitHubCodespaceSnapshot],
        current: [GitHubCodespaceSnapshot]
    ) -> (created: [GitHubCodespaceSnapshot],
          started: [GitHubCodespaceSnapshot],
          stopped: [GitHubCodespaceSnapshot],
          deleted: [GitHubCodespaceSnapshot]) {
        let priorByName = Dictionary(uniqueKeysWithValues: prior.map { ($0.codespaceName, $0) })
        let currentByName = Dictionary(uniqueKeysWithValues: current.map { ($0.codespaceName, $0) })
        var created: [GitHubCodespaceSnapshot] = []
        var started: [GitHubCodespaceSnapshot] = []
        var stopped: [GitHubCodespaceSnapshot] = []
        var deleted: [GitHubCodespaceSnapshot] = []
        for c in current {
            if let p = priorByName[c.codespaceName] {
                if p.state != c.state {
                    if c.state == "Available" {
                        started.append(c)
                    } else if c.state == "Shutdown" {
                        stopped.append(c)
                    }
                }
            } else {
                created.append(c)
            }
        }
        for p in prior where currentByName[p.codespaceName] == nil {
            deleted.append(p)
        }
        return (
            created.sorted(by: { $0.codespaceName < $1.codespaceName }),
            started.sorted(by: { $0.codespaceName < $1.codespaceName }),
            stopped.sorted(by: { $0.codespaceName < $1.codespaceName }),
            deleted.sorted(by: { $0.codespaceName < $1.codespaceName })
        )
    }

    /// Reactions diff: per-emoji (oldCount, newCount) pairs. Collector emits
    /// `reaction_received` only when `newCount > oldCount` (positive delta) —
    /// reaction removals are silent.
    public static func reactionsDiff(
        prior: GitHubIssueReactionsSnapshot,
        current: GitHubIssueReactionsSnapshot
    ) -> [(emoji: String, oldCount: Int, newCount: Int)] {
        let emojis = Set(prior.byEmoji.keys).union(current.byEmoji.keys).sorted()
        var out: [(emoji: String, oldCount: Int, newCount: Int)] = []
        for emoji in emojis {
            let old = prior.byEmoji[emoji] ?? 0
            let new = current.byEmoji[emoji] ?? 0
            if old != new {
                out.append((emoji, old, new))
            }
        }
        return out
    }

    // MARK: - Event builders

    static func makeProjectCardMovedEvent(
        itemID: String, projectID: String,
        oldStatus: String?, newStatus: String?, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.projectCardMoved.rawValue,
            Schema.EventPayloadKeys.projectV2CardId: itemID,
            Schema.EventPayloadKeys.projectV2Id: projectID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        if let s = oldStatus { payload[Schema.EventPayloadKeys.projectV2OldValue] = s }
        if let s = newStatus { payload[Schema.EventPayloadKeys.projectV2NewValue] = s }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeProjectIterationChangedEvent(
        itemID: String, projectID: String,
        oldIteration: String?, newIteration: String?, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.projectIterationChanged.rawValue,
            Schema.EventPayloadKeys.projectV2CardId: itemID,
            Schema.EventPayloadKeys.projectV2Id: projectID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        if let s = oldIteration { payload[Schema.EventPayloadKeys.projectV2OldValue] = s }
        if let s = newIteration { payload[Schema.EventPayloadKeys.projectV2NewValue] = s }
        if let s = newIteration { payload[Schema.EventPayloadKeys.iterationId] = s }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeProjectFieldUpdatedEvent(
        itemID: String, projectID: String, fieldName: String,
        oldValue: String?, newValue: String?, observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.projectFieldUpdated.rawValue,
            Schema.EventPayloadKeys.projectV2CardId: itemID,
            Schema.EventPayloadKeys.projectV2Id: projectID,
            Schema.EventPayloadKeys.projectV2FieldName: fieldName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        if let s = oldValue { payload[Schema.EventPayloadKeys.projectV2OldValue] = s }
        if let s = newValue { payload[Schema.EventPayloadKeys.projectV2NewValue] = s }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeGistCreatedEvent(_ g: GitHubGistSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.gistCreated.rawValue,
            Schema.EventPayloadKeys.gistId: g.gistID,
            Schema.EventPayloadKeys.gistDescription: g.description,
            // Mirror description under canonical `body` key so EventsFullTextStore
            // picks it up (body_kind `gh_gist_description`, Task 25 wiring).
            Schema.EventPayloadKeys.body: g.description,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeGistUpdatedEvent(_ g: GitHubGistSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.gistUpdated.rawValue,
            Schema.EventPayloadKeys.gistId: g.gistID,
            Schema.EventPayloadKeys.gistDescription: g.description,
            Schema.EventPayloadKeys.body: g.description,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeGistDeletedEvent(_ g: GitHubGistSnapshot, observedAtMs: Int64) -> RawEvent {
        // No body payload — description not preserved on deletion (snapshot is
        // gone; rebuilding from prior would lift moat'ed text into a fresh
        // event, which the spec disallows for the deletion event).
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.gistDeleted.rawValue,
            Schema.EventPayloadKeys.gistId: g.gistID,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeRepoInvitationReceivedEvent(
        _ inv: GitHubRepoInvitationSnapshot, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoInvitationReceived.rawValue,
            Schema.EventPayloadKeys.repoInvitationId: inv.invitationID,
            Schema.EventPayloadKeys.repoFullName: inv.repoFullName,
            Schema.EventPayloadKeys.repoInvitationFromLogin: inv.inviterLogin,
            Schema.EventPayloadKeys.receivedAtMs: String(inv.invitedAtMs),
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }

    static func makeRepoInvitationAcceptedEvent(
        _ inv: GitHubRepoInvitationSnapshot, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoInvitationAccepted.rawValue,
            Schema.EventPayloadKeys.repoInvitationId: inv.invitationID,
            Schema.EventPayloadKeys.repoFullName: inv.repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCodespaceCreatedEvent(_ c: GitHubCodespaceSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.codespaceCreated.rawValue,
            Schema.EventPayloadKeys.codespaceName: c.codespaceName,
            Schema.EventPayloadKeys.repoFullName: c.repoFullName,
            Schema.EventPayloadKeys.codespaceState: c.state,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCodespaceStartedEvent(_ c: GitHubCodespaceSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.codespaceStarted.rawValue,
            Schema.EventPayloadKeys.codespaceName: c.codespaceName,
            Schema.EventPayloadKeys.repoFullName: c.repoFullName,
            Schema.EventPayloadKeys.codespaceState: c.state,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCodespaceStoppedEvent(_ c: GitHubCodespaceSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.codespaceStopped.rawValue,
            Schema.EventPayloadKeys.codespaceName: c.codespaceName,
            Schema.EventPayloadKeys.repoFullName: c.repoFullName,
            Schema.EventPayloadKeys.codespaceState: c.state,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeCodespaceDeletedEvent(_ c: GitHubCodespaceSnapshot, observedAtMs: Int64) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.codespaceDeleted.rawValue,
            Schema.EventPayloadKeys.codespaceName: c.codespaceName,
            Schema.EventPayloadKeys.repoFullName: c.repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeIssueReactionReceivedEvent(
        _ snap: GitHubIssueReactionsSnapshot, emoji: String, delta: Int, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.issueReactionReceived.rawValue,
            Schema.EventPayloadKeys.repoFullName: "\(snap.owner)/\(snap.repo)",
            "issue_number": String(snap.issueNumber),
            Schema.EventPayloadKeys.reactionEmoji: emoji,
            Schema.EventPayloadKeys.reactionCount: String(snap.byEmoji[emoji] ?? 0),
            Schema.EventPayloadKeys.reactionDelta: String(delta),
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .context, bundleID: nil, payload: payload
        )
    }
}

// Codable conformances live on the value types themselves in
// GitHubAPISnapshots.swift — required because Swift can only synthesize
// Codable in the file that declares the struct.
