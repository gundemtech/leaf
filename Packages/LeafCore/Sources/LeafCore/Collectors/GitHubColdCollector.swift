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

import Foundation
import os

public actor GitHubColdCollector {
    /// Top-N most-active repos to fan out per alert type. 14-day lookback —
    /// different from warm tier's 7-day issue-reactions window per spec.
    public static let alertReposTopN = 10
    public static let alertReposLookbackDays = 14

    private let database: Database
    private let provider: any GitHubAPIProvider
    private let refresher: GitHubTokenRefresher
    private let scopeService: any GitHubScopesChecking
    private let intervalSec: TimeInterval  // not used directly (scheduled externally)
    private let logger: Logger

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

    // MARK: - performTick

    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .github)
        } catch {
            logger.error("cold readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }
        guard record != nil else { return TickResult(skipped: true, eventsEmitted: 0) }

        // 2. Token refresh.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch GitHubTokenRefresherError.refreshDenied(let msg) {
            logger.warning("cold refresh denied: \(msg, privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        } catch {
            logger.error("cold refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsEmitted: 0)
        }

        let login = refreshed.workspaceName
        let sourceID = "github:cold:\(login)"
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        var events: [RawEvent] = []
        var snapshots: [ProviderSnapshot] = []

        // --- 3a. Starred repos (set diff) --------------------------------------
        do {
            let current = try await provider.fetchStarredRepos(
                accessToken: refreshed.accessToken, login: login
            )
            ingestStarred(current, nowMs: nowMs, events: &events, snapshots: &snapshots)
        } catch {
            logger.error("fetchStarredRepos failed: \(String(describing: error), privacy: .public)")
        }

        // --- 3b. Watched repos (set diff) --------------------------------------
        do {
            let current = try await provider.fetchWatchedRepos(
                accessToken: refreshed.accessToken, login: login
            )
            ingestWatched(current, nowMs: nowMs, events: &events, snapshots: &snapshots)
        } catch {
            logger.error("fetchWatchedRepos failed: \(String(describing: error), privacy: .public)")
        }

        // --- 3c. Security alerts (scope-gated bounded fan-out) -----------------
        if await scopeService.has("security_events") {
            let lookbackMs = Int64(Self.alertReposLookbackDays) * 86_400_000
            let activeRepos: [String]
            do {
                activeRepos = try database.queryActiveGitHubRepos(
                    sinceMs: nowMs - lookbackMs,
                    limit: Self.alertReposTopN
                )
            } catch {
                logger.error("queryActiveGitHubRepos failed: \(String(describing: error), privacy: .public)")
                activeRepos = []
            }
            for repoFullName in activeRepos {
                guard let parsed = Self.parseRepoFullName(repoFullName) else { continue }
                await ingestRepoAlerts(
                    repoFullName: repoFullName,
                    owner: parsed.owner, repo: parsed.repo,
                    accessToken: refreshed.accessToken, nowMs: nowMs,
                    events: &events, snapshots: &snapshots
                )
            }
        } else if !didLogSecurityScopeWarn {
            logger.warning("security_events scope missing — skipping all alert endpoints (one-time warn per session)")
            didLogSecurityScopeWarn = true
        }

        // --- 3d. Org membership + audit log ------------------------------------
        let orgs: [GitHubOrgSnapshot]
        do {
            orgs = try await provider.fetchOrganizations(accessToken: refreshed.accessToken)
        } catch {
            logger.error("fetchOrganizations failed: \(String(describing: error), privacy: .public)")
            orgs = []
        }
        if !orgs.isEmpty, await scopeService.has("read:audit_log") {
            let priorCursor = readAuditCursor()
            var newCursor: Int64? = priorCursor
            for org in orgs {
                do {
                    let batch = try await provider.fetchOrgAuditLog(
                        accessToken: refreshed.accessToken, org: org.login, since: priorCursor
                    )
                    for entry in batch.entries {
                        events.append(Self.makeAuditActionObservedEvent(entry, observedAtMs: nowMs))
                        if let cur = newCursor {
                            if entry.createdAtMs > cur { newCursor = entry.createdAtMs }
                        } else {
                            newCursor = entry.createdAtMs
                        }
                    }
                    if let c = batch.cursorMs {
                        if let cur = newCursor {
                            if c > cur { newCursor = c }
                        } else {
                            newCursor = c
                        }
                    }
                } catch {
                    logger.error("fetchOrgAuditLog \(org.login, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            // Persist cursor — even if unchanged, harmless (UPSERT idempotent).
            snapshots.append(makeAuditCursorSnapshot(since: newCursor, capturedAtMs: nowMs))
        }

        // --- 4. Build offset row -----------------------------------------------
        let offset = CollectorOffset(
            collectorID: CollectorID.githubColdPolling,
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
            logger.error("cold persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsEmitted: 0)
        }
        if !events.isEmpty {
            logger.info("github cold tick wrote \(events.count, privacy: .public) events")
        }
        return TickResult(skipped: false, eventsEmitted: events.count)
    }

    // MARK: - Endpoint ingestion

    private func ingestStarred(
        _ current: [GitHubStarredRepoSnapshot],
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind = Schema.ProviderSnapshotKinds.githubStarredRepos
        let priorPresent = snapshotRowPresent(kind: kind)
        let priorRepos: [String] = readStarredSnapshot()
        let currentRepos = current.map { $0.repoFullName }
        if priorPresent {
            let d = Self.starredDiff(prior: priorRepos, current: currentRepos)
            // Build lookup for starredAt timestamps (current items only — unstars
            // don't carry timestamps).
            let byName = Dictionary(uniqueKeysWithValues: current.map { ($0.repoFullName, $0.starredAtMs) })
            for repo in d.starred {
                events.append(Self.makeRepoStarredEvent(
                    repoFullName: repo,
                    starredAtMs: byName[repo] ?? nowMs,
                    observedAtMs: nowMs
                ))
            }
            for repo in d.unstarred {
                events.append(Self.makeRepoUnstarredEvent(repoFullName: repo, observedAtMs: nowMs))
            }
        }
        snapshots.append(makeStarredSnapshot(currentRepos, capturedAtMs: nowMs))
    }

    private func ingestWatched(
        _ current: [GitHubWatchedRepoSnapshot],
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind = Schema.ProviderSnapshotKinds.githubWatchedRepos
        let priorPresent = snapshotRowPresent(kind: kind)
        let priorRepos: [String] = readWatchedSnapshot()
        let currentRepos = current.map { $0.repoFullName }
        if priorPresent {
            let d = Self.watchedDiff(prior: priorRepos, current: currentRepos)
            for repo in d.watched {
                events.append(Self.makeRepoWatchedEvent(repoFullName: repo, observedAtMs: nowMs))
            }
            for repo in d.unwatched {
                events.append(Self.makeRepoUnwatchedEvent(repoFullName: repo, observedAtMs: nowMs))
            }
        }
        snapshots.append(makeWatchedSnapshot(currentRepos, capturedAtMs: nowMs))
    }

    private func ingestRepoAlerts(
        repoFullName: String,
        owner: String, repo: String,
        accessToken: String,
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) async {
        // Secret.
        do {
            let current = try await provider.fetchSecretScanningAlerts(
                accessToken: accessToken, owner: owner, repo: repo
            )
            ingestAlertSet(
                kind: .secret,
                snapshotPrefix: Schema.ProviderSnapshotKinds.githubSecretAlertsPrefix,
                repoFullName: repoFullName, current: current,
                observedKind: .secretAlertObserved, resolvedKind: .secretAlertResolved,
                nowMs: nowMs, events: &events, snapshots: &snapshots
            )
        } catch {
            logger.error("fetchSecretScanningAlerts \(repoFullName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        // Code.
        do {
            let current = try await provider.fetchCodeScanningAlerts(
                accessToken: accessToken, owner: owner, repo: repo
            )
            ingestAlertSet(
                kind: .code,
                snapshotPrefix: Schema.ProviderSnapshotKinds.githubCodeAlertsPrefix,
                repoFullName: repoFullName, current: current,
                observedKind: .codeAlertObserved, resolvedKind: .codeAlertResolved,
                nowMs: nowMs, events: &events, snapshots: &snapshots
            )
        } catch {
            logger.error("fetchCodeScanningAlerts \(repoFullName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        // Dependabot.
        do {
            let current = try await provider.fetchDependabotAlerts(
                accessToken: accessToken, owner: owner, repo: repo
            )
            ingestAlertSet(
                kind: .dependabot,
                snapshotPrefix: Schema.ProviderSnapshotKinds.githubDependabotAlertsPrefix,
                repoFullName: repoFullName, current: current,
                observedKind: .dependabotAlertObserved, resolvedKind: .dependabotAlertResolved,
                nowMs: nowMs, events: &events, snapshots: &snapshots
            )
        } catch {
            logger.error("fetchDependabotAlerts \(repoFullName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func ingestAlertSet(
        kind: GitHubSecurityAlertSnapshot.Kind,
        snapshotPrefix: String,
        repoFullName: String,
        current: [GitHubSecurityAlertSnapshot],
        observedKind: GitHubEventKindKey,
        resolvedKind: GitHubEventKindKey,
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let snapshotKind = snapshotPrefix + repoFullName
        let priorPresent = snapshotRowPresent(kind: snapshotKind)
        let prior: [GitHubSecurityAlertSnapshot] = readAlertsSnapshot(kind: snapshotKind)
        if priorPresent {
            let d = Self.securityAlertsDiff(prior: prior, current: current)
            for a in d.observed {
                events.append(Self.makeSecurityAlertEvent(eventKind: observedKind, alert: a, observedAtMs: nowMs))
            }
            for a in d.resolved {
                events.append(Self.makeSecurityAlertEvent(eventKind: resolvedKind, alert: a, observedAtMs: nowMs))
            }
        }
        snapshots.append(makeAlertsSnapshot(snapshotKind: snapshotKind, alerts: current, capturedAtMs: nowMs))
    }

    // MARK: - Snapshot read / encode helpers

    // Internal Codable wrappers (mirror Linear D1 pattern: keep value types
    // free of Codable and confine JSON shape decisions to the collector).

    private struct StarredSnapshotJSON: Codable {
        let repos: [String]
    }
    private struct WatchedSnapshotJSON: Codable {
        let repos: [String]
    }
    private struct AlertsSnapshotJSON: Codable {
        struct A: Codable {
            let kind: String
            let repoFullName: String
            let alertNumber: Int
            let severity: String
            let rule: String
            let packageName: String?
            let state: String
            let createdAtMs: Int64
            let updatedAtMs: Int64
        }
        let alerts: [A]
    }
    private struct AuditCursorJSON: Codable {
        let since: Int64?
    }

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

    private func readStarredSnapshot() -> [String] {
        guard let snap = readRawSnapshot(Schema.ProviderSnapshotKinds.githubStarredRepos) else { return [] }
        return (try? JSONDecoder().decode(StarredSnapshotJSON.self, from: Data(snap.snapshotJSON.utf8)).repos) ?? []
    }

    private func readWatchedSnapshot() -> [String] {
        guard let snap = readRawSnapshot(Schema.ProviderSnapshotKinds.githubWatchedRepos) else { return [] }
        return (try? JSONDecoder().decode(WatchedSnapshotJSON.self, from: Data(snap.snapshotJSON.utf8)).repos) ?? []
    }

    private func readAlertsSnapshot(kind: String) -> [GitHubSecurityAlertSnapshot] {
        guard let snap = readRawSnapshot(kind) else { return [] }
        guard let parsed = try? JSONDecoder().decode(AlertsSnapshotJSON.self, from: Data(snap.snapshotJSON.utf8)) else {
            return []
        }
        return parsed.alerts.compactMap { a in
            guard let k = GitHubSecurityAlertSnapshot.Kind(rawValue: a.kind) else { return nil }
            return GitHubSecurityAlertSnapshot(
                kind: k, repoFullName: a.repoFullName, alertNumber: a.alertNumber,
                severity: a.severity, rule: a.rule, packageName: a.packageName,
                state: a.state, createdAtMs: a.createdAtMs, updatedAtMs: a.updatedAtMs
            )
        }
    }

    private func readAuditCursor() -> Int64? {
        guard let snap = readRawSnapshot(Schema.ProviderSnapshotKinds.githubAuditCursor) else { return nil }
        return (try? JSONDecoder().decode(AuditCursorJSON.self, from: Data(snap.snapshotJSON.utf8)).since)
            ?? nil
    }

    private func readRawSnapshot(_ kind: String) -> ProviderSnapshot? {
        let outer: ProviderSnapshot?? = try? database.readSQL { raw in
            try ProviderSnapshotsStore.read(provider: "github", snapshotKind: kind, in: raw)
        }
        return outer.flatMap { $0 }
    }

    private func makeStarredSnapshot(_ repos: [String], capturedAtMs: Int64) -> ProviderSnapshot {
        let payload = StarredSnapshotJSON(repos: repos)
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"repos\":[]}"
        return ProviderSnapshot(
            provider: "github",
            snapshotKind: Schema.ProviderSnapshotKinds.githubStarredRepos,
            snapshotJSON: s, capturedAtMs: capturedAtMs
        )
    }

    private func makeWatchedSnapshot(_ repos: [String], capturedAtMs: Int64) -> ProviderSnapshot {
        let payload = WatchedSnapshotJSON(repos: repos)
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"repos\":[]}"
        return ProviderSnapshot(
            provider: "github",
            snapshotKind: Schema.ProviderSnapshotKinds.githubWatchedRepos,
            snapshotJSON: s, capturedAtMs: capturedAtMs
        )
    }

    private func makeAlertsSnapshot(snapshotKind: String, alerts: [GitHubSecurityAlertSnapshot], capturedAtMs: Int64) -> ProviderSnapshot {
        let payload = AlertsSnapshotJSON(alerts: alerts.map { a in
            .init(
                kind: a.kind.rawValue, repoFullName: a.repoFullName, alertNumber: a.alertNumber,
                severity: a.severity, rule: a.rule, packageName: a.packageName,
                state: a.state, createdAtMs: a.createdAtMs, updatedAtMs: a.updatedAtMs
            )
        })
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"alerts\":[]}"
        return ProviderSnapshot(
            provider: "github", snapshotKind: snapshotKind,
            snapshotJSON: s, capturedAtMs: capturedAtMs
        )
    }

    private func makeAuditCursorSnapshot(since: Int64?, capturedAtMs: Int64) -> ProviderSnapshot {
        let payload = AuditCursorJSON(since: since)
        let s = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"since\":null}"
        return ProviderSnapshot(
            provider: "github",
            snapshotKind: Schema.ProviderSnapshotKinds.githubAuditCursor,
            snapshotJSON: s, capturedAtMs: capturedAtMs
        )
    }

    // MARK: - Repo full-name parsing

    static func parseRepoFullName(_ name: String) -> (owner: String, repo: String)? {
        let parts = name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: - Diff helpers (pure)

    /// Returns repos appearing in `current` but not `prior` (= starred) and
    /// vice versa (= unstarred). Inputs are lists of `repoFullName` strings.
    public static func starredDiff(
        prior: [String], current: [String]
    ) -> (starred: [String], unstarred: [String]) {
        let priorSet = Set(prior)
        let currentSet = Set(current)
        let starred = Array(currentSet.subtracting(priorSet)).sorted()
        let unstarred = Array(priorSet.subtracting(currentSet)).sorted()
        return (starred, unstarred)
    }

    /// Same shape as `starredDiff` — repos appearing in `current` but not
    /// `prior` are watched, vice versa unwatched.
    public static func watchedDiff(
        prior: [String], current: [String]
    ) -> (watched: [String], unwatched: [String]) {
        let priorSet = Set(prior)
        let currentSet = Set(current)
        let watched = Array(currentSet.subtracting(priorSet)).sorted()
        let unwatched = Array(priorSet.subtracting(currentSet)).sorted()
        return (watched, unwatched)
    }

    /// Composite key = (kind, repoFullName, alertNumber).
    /// `observed` = current \ prior (by composite key), plus rows whose prior
    /// state was resolved/fixed/dismissed AND current state is open
    /// (re-observation).
    /// `resolved` = prior \ current, plus rows whose state transitioned from
    /// open to fixed/resolved/dismissed.
    public static func securityAlertsDiff(
        prior: [GitHubSecurityAlertSnapshot],
        current: [GitHubSecurityAlertSnapshot]
    ) -> (observed: [GitHubSecurityAlertSnapshot], resolved: [GitHubSecurityAlertSnapshot]) {
        struct Key: Hashable {
            let kind: GitHubSecurityAlertSnapshot.Kind
            let repo: String
            let number: Int
        }
        let priorByKey = Dictionary(uniqueKeysWithValues: prior.map { (Key(kind: $0.kind, repo: $0.repoFullName, number: $0.alertNumber), $0) })
        let currentByKey = Dictionary(uniqueKeysWithValues: current.map { (Key(kind: $0.kind, repo: $0.repoFullName, number: $0.alertNumber), $0) })
        let resolvedStates: Set<String> = ["fixed", "resolved", "dismissed"]
        let openStates: Set<String> = ["open"]

        var observed: [GitHubSecurityAlertSnapshot] = []
        var resolved: [GitHubSecurityAlertSnapshot] = []

        for (k, c) in currentByKey {
            if let p = priorByKey[k] {
                // State transition.
                if resolvedStates.contains(p.state) && openStates.contains(c.state) {
                    observed.append(c)
                } else if openStates.contains(p.state) && resolvedStates.contains(c.state) {
                    resolved.append(c)
                }
            } else {
                // Brand new key — observed.
                observed.append(c)
            }
        }
        for (k, p) in priorByKey where currentByKey[k] == nil {
            // Disappeared from current → resolved (treat as cleared).
            resolved.append(p)
        }
        return (
            observed.sorted(by: alertOrder),
            resolved.sorted(by: alertOrder)
        )
    }

    private static func alertOrder(_ a: GitHubSecurityAlertSnapshot, _ b: GitHubSecurityAlertSnapshot) -> Bool {
        if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
        if a.repoFullName != b.repoFullName { return a.repoFullName < b.repoFullName }
        return a.alertNumber < b.alertNumber
    }

    // MARK: - Event builders

    static func makeRepoStarredEvent(
        repoFullName: String, starredAtMs: Int64, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoStarred.rawValue,
            Schema.EventPayloadKeys.repoFullName: repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(starredAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeRepoUnstarredEvent(
        repoFullName: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoUnstarred.rawValue,
            Schema.EventPayloadKeys.repoFullName: repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeRepoWatchedEvent(
        repoFullName: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoWatched.rawValue,
            Schema.EventPayloadKeys.repoFullName: repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeRepoUnwatchedEvent(
        repoFullName: String, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.repoUnwatched.rawValue,
            Schema.EventPayloadKeys.repoFullName: repoFullName,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeSecurityAlertEvent(
        eventKind: GitHubEventKindKey,
        alert: GitHubSecurityAlertSnapshot,
        observedAtMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": eventKind.rawValue,
            Schema.EventPayloadKeys.repoFullName: alert.repoFullName,
            Schema.EventPayloadKeys.alertNumber: String(alert.alertNumber),
            Schema.EventPayloadKeys.alertSeverity: alert.severity,
            Schema.EventPayloadKeys.alertRule: alert.rule,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        if let pkg = alert.packageName {
            payload[Schema.EventPayloadKeys.dependabotPackageName] = pkg
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(observedAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }

    static func makeAuditActionObservedEvent(
        _ entry: GitHubAuditLogEntry, observedAtMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.auditActionObserved.rawValue,
            Schema.EventPayloadKeys.auditAction: entry.action,
            Schema.EventPayloadKeys.auditActorLogin: entry.actorLogin,
            Schema.EventPayloadKeys.observedAtMs: String(observedAtMs)
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(entry.createdAtMs) / 1000.0),
            signalType: .action, bundleID: nil, payload: payload
        )
    }
}
