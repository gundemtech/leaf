//
//  GitHubColdCollector+Tick.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — `performTick` orchestration + per-
//  endpoint ingestion helpers moved out of GitHubColdCollector.swift.
//  Pure relocation; no behavioural change.
//

import Foundation

extension GitHubColdCollector {
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
                    RepoAlertsRequest(
                        repoFullName: repoFullName,
                        owner: parsed.owner, repo: parsed.repo,
                        accessToken: refreshed.accessToken, nowMs: nowMs
                    ),
                    events: &events, snapshots: &snapshots
                )
            }
        } else if !didLogSecurityScopeWarn {
            logger.warning("security_events scope missing — skipping all alert endpoints (one-time warn per session)")
            markSecurityScopeWarnLogged()
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
                    logger.error(
                        "fetchOrgAuditLog \(org.login, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                    )
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

    func ingestStarred(
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
                events.append(
                    Self.makeRepoStarredEvent(
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

    func ingestWatched(
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

    /// Per-repo input bundle for ``ingestRepoAlerts(_:events:snapshots:)``.
    /// Groups the repo identifier, owner/repo split, auth token, and tick
    /// timestamp so the alert-fetch fan-out signature stays digestible.
    /// `events` / `snapshots` are passed as `inout` arrays at the boundary —
    /// can't live on the value type.
    struct RepoAlertsRequest {
        let repoFullName: String
        let owner: String
        let repo: String
        let accessToken: String
        let nowMs: Int64
    }

    func ingestRepoAlerts(
        _ req: RepoAlertsRequest,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) async {
        let repoFullName = req.repoFullName
        let owner = req.owner
        let repo = req.repo
        let accessToken = req.accessToken
        let nowMs = req.nowMs
        // Secret.
        do {
            let current = try await provider.fetchSecretScanningAlerts(
                accessToken: accessToken, owner: owner, repo: repo
            )
            ingestAlertSet(
                AlertSetRequest(
                    kind: .secret,
                    snapshotPrefix: Schema.ProviderSnapshotKinds.githubSecretAlertsPrefix,
                    repoFullName: repoFullName, current: current,
                    observedKind: .secretAlertObserved, resolvedKind: .secretAlertResolved,
                    nowMs: nowMs
                ),
                events: &events, snapshots: &snapshots
            )
        } catch {
            logger.error(
                "fetchSecretScanningAlerts \(repoFullName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
        // Code.
        do {
            let current = try await provider.fetchCodeScanningAlerts(
                accessToken: accessToken, owner: owner, repo: repo
            )
            ingestAlertSet(
                AlertSetRequest(
                    kind: .code,
                    snapshotPrefix: Schema.ProviderSnapshotKinds.githubCodeAlertsPrefix,
                    repoFullName: repoFullName, current: current,
                    observedKind: .codeAlertObserved, resolvedKind: .codeAlertResolved,
                    nowMs: nowMs
                ),
                events: &events, snapshots: &snapshots
            )
        } catch {
            logger.error(
                "fetchCodeScanningAlerts \(repoFullName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
        // Dependabot.
        do {
            let current = try await provider.fetchDependabotAlerts(
                accessToken: accessToken, owner: owner, repo: repo
            )
            ingestAlertSet(
                AlertSetRequest(
                    kind: .dependabot,
                    snapshotPrefix: Schema.ProviderSnapshotKinds.githubDependabotAlertsPrefix,
                    repoFullName: repoFullName, current: current,
                    observedKind: .dependabotAlertObserved, resolvedKind: .dependabotAlertResolved,
                    nowMs: nowMs
                ),
                events: &events, snapshots: &snapshots
            )
        } catch {
            logger.error(
                "fetchDependabotAlerts \(repoFullName, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Per-alert-kind ingestion request for ``ingestAlertSet(_:events:snapshots:)``.
    /// Groups the alert-kind identifier (snapshot key prefix + diff-target
    /// flavour), the freshly fetched alert list, and the started/resolved
    /// event-kind discriminators emitted on the diff. `events` / `snapshots`
    /// stay as `inout` arrays at the boundary.
    struct AlertSetRequest {
        let kind: GitHubSecurityAlertSnapshot.Kind
        let snapshotPrefix: String
        let repoFullName: String
        let current: [GitHubSecurityAlertSnapshot]
        let observedKind: GitHubEventKindKey
        let resolvedKind: GitHubEventKindKey
        let nowMs: Int64
    }

    func ingestAlertSet(
        _ req: AlertSetRequest,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let snapshotKind = req.snapshotPrefix + req.repoFullName
        let priorPresent = snapshotRowPresent(kind: snapshotKind)
        let prior: [GitHubSecurityAlertSnapshot] = readAlertsSnapshot(kind: snapshotKind)
        if priorPresent {
            let d = Self.securityAlertsDiff(prior: prior, current: req.current)
            for a in d.observed {
                events.append(Self.makeSecurityAlertEvent(eventKind: req.observedKind, alert: a, observedAtMs: req.nowMs))
            }
            for a in d.resolved {
                events.append(Self.makeSecurityAlertEvent(eventKind: req.resolvedKind, alert: a, observedAtMs: req.nowMs))
            }
        }
        snapshots.append(makeAlertsSnapshot(snapshotKind: snapshotKind, alerts: req.current, capturedAtMs: req.nowMs))
    }
}
