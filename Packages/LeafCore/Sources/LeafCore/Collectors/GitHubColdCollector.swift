//
//  GitHubColdCollector.swift
//  LeafCore
//
//  Phase Track-3 D2 — GitHub cold-tier (4am local, daily) collector. Mirrors
//  `LinearColdCollector` shape (actor + start/stop loop + performTick + atomic
//  write through `Database.writeEventsOffsetsAndSnapshots`). Five endpoint
//  groups, 11 event_kinds:
//   1. fetchStarredRepos → gh_repo_starred / gh_repo_unstarred (set diff,
//      singleton snapshot `github_starred_repos`).
//   2. fetchWatchedRepos → gh_repo_watched / gh_repo_unwatched (set diff,
//      singleton snapshot `github_watched_repos`).
//   3. fetchSecretScanningAlerts / fetchCodeScanningAlerts /
//      fetchDependabotAlerts → 6 event_kinds (3 × observed/resolved). Bounded
//      fan-out over `Database.queryActiveGitHubRepos(sinceMs:limit:)` (14-day
//      window, top 10). Per-repo failure tolerance. Scope-gated on
//      `security_events`. Snapshot prefixes:
//      `github_secret_alerts:<repoFullName>`,
//      `github_code_alerts:<repoFullName>`,
//      `github_dependabot_alerts:<repoFullName>`.
//   4. fetchOrganizations → no event emission. Helper that decides whether to
//      call audit log.
//   5. fetchOrgAuditLog → gh_audit_action_observed. Gated on `read:audit_log`
//      scope + non-empty org membership. Cursor in `github_audit_cursor`
//      provider snapshot, JSON `{since: Int64}`.
//
//  Bootstrap discipline (mirror Linear D1): first tick with no prior snapshot
//  emits zero diff events but writes the new snapshot — Day-2 emits the
//  normal added/removed stream.
//
//  Atomic write through `Database.writeEventsOffsetsAndSnapshots`. Single
//  offset row `github:cold:<login>` whose `lastModifiedMs` is the tick wall
//  clock (used by `GitHubColdScheduler` catch-up gate in Task 11).
//
//  Privacy (ADR-010 §6): event payloads carry public-safe metadata only.
//  - Starred / watched / invitation: repo full-name only.
//  - Security alert: severity + rule (CVE / advisory id) + state + alert
//    number; NO description / NO secret content.
//  - Audit log: action discriminator + actor login + observed_at_ms; NO
//    description / NO data.* free-form.
//
//  Phase 2.3.C.3 split — `performTick` + endpoint ingestion live in
//  `GitHubColdCollector+Tick.swift`; static event builders + diff helpers
//  in `GitHubColdCollector+EventBuilders.swift`; snapshot read/encode
//  helpers in `GitHubColdCollector+Snapshots.swift`.
//

import Foundation
import os

public actor GitHubColdCollector {
    /// Top-N most-active repos to fan out per alert type. 14-day lookback —
    /// different from warm tier's 7-day issue-reactions window per spec.
    public static let alertReposTopN = 10
    public static let alertReposLookbackDays = 14

    let database: Database
    let provider: any GitHubAPIProvider
    let refresher: GitHubTokenRefresher
    let scopeService: any GitHubScopesChecking
    private let intervalSec: TimeInterval  // not used directly (scheduled externally)
    let logger: Logger

    private var loopTask: Task<Void, Never>?

    /// One-shot warn flag — fires exactly once per collector instance to avoid
    /// log spam when the user keeps the integration connected without granting
    /// the optional `security_events` scope.
    private(set) var didLogSecurityScopeWarn: Bool = false

    public init(
        database: Database,
        provider: any GitHubAPIProvider,
        refresher: GitHubTokenRefresher,
        scopeService: any GitHubScopesChecking,
        intervalSec: TimeInterval = 86_400,
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
        // Cold tier is driven by GitHubColdScheduler (4am anchor). start()/stop()
        // here exist for symmetry — actual cadence is owned by the scheduler.
        logger.info("GitHubColdCollector ready")
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        logger.info("GitHubColdCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let eventsEmitted: Int
        public init(skipped: Bool, eventsEmitted: Int) {
            self.skipped = skipped
            self.eventsEmitted = eventsEmitted
        }
    }

    /// Setter for the one-shot security-scope warn flag — extensions can't
    /// assign to `private(set) var`, so the Tick extension flips this through
    /// the actor-internal mutator.
    func markSecurityScopeWarnLogged() {
        didLogSecurityScopeWarn = true
    }
}
