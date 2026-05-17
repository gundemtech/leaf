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
//  Phase 2.3.C.3 split — `performTick` + endpoint ingestion live in
//  `GitHubWarmCollector+Ingest.swift`; static event builders + diff helpers
//  in `GitHubWarmCollector+EventBuilders.swift`.
//

import Foundation
import os

public actor GitHubWarmCollector {
    public static let projectsV2TopN = 10
    public static let issueReactionsTopK = 10
    public static let issueReactionsLookbackDays = 7

    let database: Database
    let provider: any GitHubAPIProvider
    let refresher: GitHubTokenRefresher
    let scopeService: any GitHubScopesChecking
    let intervalSec: TimeInterval
    let logger: Logger

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

    // MARK: - Snapshot helpers

    func snapshotRowPresent(kind: String) -> Bool {
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

    func readSnapshotArray<T: Decodable>(kind: String) -> [T] {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "github", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: Data(s.snapshotJSON.utf8))) ?? []
    }

    func readSnapshotValue<T: Decodable>(kind: String) -> T? {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(
                provider: "github", snapshotKind: kind, in: raw
            )
        }
        guard let s = outer.flatMap({ $0 }) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(s.snapshotJSON.utf8))
    }

    func makeSnapshot<T: Encodable>(kind: String, encoding value: T, nowMs: Int64) -> ProviderSnapshot {
        let json: String
        if let data = try? JSONEncoder().encode(value),
            let s = String(data: data, encoding: .utf8)
        {
            json = s
        } else {
            json = "[]"
        }
        return ProviderSnapshot(
            provider: "github", snapshotKind: kind,
            snapshotJSON: json, capturedAtMs: nowMs
        )
    }
}

// Codable conformances live on the value types themselves in
// GitHubAPISnapshots.swift — required because Swift can only synthesize
// Codable in the file that declares the struct.
