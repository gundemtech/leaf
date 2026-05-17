//
//  GitHubWarmCollector+Ingest.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.3) — `performTick` orchestration + per-
//  endpoint ingestion helpers + runLoop. Pure relocation from
//  GitHubWarmCollector.swift.
//

import Foundation

extension GitHubWarmCollector {
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
                logger.error(
                    "fetchIssueReactions \(ref, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
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

    func runLoop() async {
        // Stagger by half the interval — mirrors LinearWarmCollector pattern.
        try? await Task.sleep(nanoseconds: UInt64(max(0, intervalSec / 2) * 1_000_000_000))
        while !Task.isCancelled {
            _ = await performTick()
            try? await Task.sleep(nanoseconds: UInt64(max(0, intervalSec) * 1_000_000_000))
        }
    }

    // MARK: - Endpoint ingestion (mutates events + snapshots arrays)

    func ingestProjectsV2(
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
                    events.append(
                        Self.makeProjectCardMovedEvent(
                            itemID: row.itemID, projectID: row.projectID,
                            oldStatus: row.oldStatus, newStatus: row.newStatus,
                            observedAtMs: nowMs
                        ))
                }
                for row in iter {
                    events.append(
                        Self.makeProjectIterationChangedEvent(
                            itemID: row.itemID, projectID: row.projectID,
                            oldIteration: row.oldIteration, newIteration: row.newIteration,
                            observedAtMs: nowMs
                        ))
                }
                for row in fields {
                    events.append(
                        Self.makeProjectFieldUpdatedEvent(
                            itemID: row.itemID, projectID: row.projectID, fieldName: row.fieldName,
                            oldValue: row.oldValue, newValue: row.newValue, observedAtMs: nowMs
                        ))
                }
            }
            // Always write the current snapshot (bootstrap discipline: first
            // tick writes only).
            snapshots.append(makeSnapshot(kind: kind, encoding: project.items, nowMs: nowMs))
        }
    }

    func ingestGists(
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

    func ingestInvitations(
        _ current: [GitHubRepoInvitationSnapshot],
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind = Schema.ProviderSnapshotKinds.githubRepoInvitations
        let prior: [GitHubRepoInvitationSnapshot] = readSnapshotArray(kind: kind)
        if snapshotRowPresent(kind: kind) {
            let (received, accepted) = Self.invitationsDiff(prior: prior, current: current)
            events.append(
                contentsOf: received.map {
                    Self.makeRepoInvitationReceivedEvent($0, observedAtMs: nowMs)
                })
            events.append(
                contentsOf: accepted.map {
                    Self.makeRepoInvitationAcceptedEvent($0, observedAtMs: nowMs)
                })
        }
        snapshots.append(makeSnapshot(kind: kind, encoding: current, nowMs: nowMs))
    }

    func ingestCodespaces(
        _ current: [GitHubCodespaceSnapshot],
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind = Schema.ProviderSnapshotKinds.githubCodespaces
        let prior: [GitHubCodespaceSnapshot] = readSnapshotArray(kind: kind)
        if snapshotRowPresent(kind: kind) {
            let diff = Self.codespacesDiff(prior: prior, current: current)
            events.append(
                contentsOf: diff.created.map {
                    Self.makeCodespaceCreatedEvent($0, observedAtMs: nowMs)
                })
            events.append(
                contentsOf: diff.started.map {
                    Self.makeCodespaceStartedEvent($0, observedAtMs: nowMs)
                })
            events.append(
                contentsOf: diff.stopped.map {
                    Self.makeCodespaceStoppedEvent($0, observedAtMs: nowMs)
                })
            events.append(
                contentsOf: diff.deleted.map {
                    Self.makeCodespaceDeletedEvent($0, observedAtMs: nowMs)
                })
        }
        snapshots.append(makeSnapshot(kind: kind, encoding: current, nowMs: nowMs))
    }

    func ingestIssueReactions(
        _ current: GitHubIssueReactionsSnapshot,
        nowMs: Int64,
        events: inout [RawEvent],
        snapshots: inout [ProviderSnapshot]
    ) {
        let kind =
            Schema.ProviderSnapshotKinds.githubIssueReactionsPrefix
            + "\(current.owner)/\(current.repo)#\(current.issueNumber)"
        let prior: GitHubIssueReactionsSnapshot =
            readSnapshotValue(kind: kind)
            ?? .empty(
                owner: current.owner, repo: current.repo,
                issueNumber: current.issueNumber, nowMs: 0)
        if snapshotRowPresent(kind: kind) {
            let deltas = Self.reactionsDiff(prior: prior, current: current)
            for delta in deltas where delta.newCount > delta.oldCount {
                events.append(
                    Self.makeIssueReactionReceivedEvent(
                        current, emoji: delta.emoji,
                        delta: delta.newCount - delta.oldCount,
                        observedAtMs: nowMs
                    ))
            }
        }
        snapshots.append(makeSnapshot(kind: kind, encoding: current, nowMs: nowMs))
    }
}
