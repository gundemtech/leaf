//
//  GitHubCollector.swift
//  LeafCore
//
//  Phase 4.3 — GitHub REST events polling collector. Once per `intervalSec`:
//  1. Reads the `integrations` row (provider=.github). None → skip.
//  2. `refresher.refreshIfNeeded(now:)` — refresh the access token if it is expiring.
//     On `.refreshDenied` (invalid_grant) the refresher has already done deleteIntegration
//     + UserDefaults flag + DistributedNotification → UI surfaces "Reconnect needed".
//  3. `provider.fetchEvents(token, login, since:)` — REST GET /users/<login>/events.
//     `since` = stored `lastModifiedMs` (max `created_at` from the previous tick);
//     bootstrap → `nil` → provider uses the first page of the feed (~90d max).
//  4. Map the result into `[RawEvent]` with `signal_type=.action`, `payload.source=github`.
//  5. Atomic write via `writeEventsAndOffset(events:offset:)` — events + cursor
//     in one transaction. Cursor = `batch.cursorMs` (newest createdAt).
//

import Foundation
import os

public actor GitHubCollector {
    /// Phase 4.7.B-3 — top-N most-recently-pushed repos cap for bounded fan-out
    /// `actions/runs` polling. N=10 → ≤10 HTTP calls per tick on top of the baseline events
    /// fetch; conservative under the 5000/hr primary rate-limit (12 ticks/hr × 10 calls = 120/hr).
    /// TODO(B-5+): activeReposCap may need to drop to 5-7 once check_runs and
    /// contributions land — verify GitHub REST budget headroom (B-4 add ≤K
    /// check-runs calls per tick where K = unique pushed shas; B-5 daily
    /// contributions GraphQL — separate budget, not per-tick).
    private static let activeReposCap = 10
    /// Phase 4.7.B-3 — sliding window for deriving active repos from the `events` table.
    /// 7 days — enough to catch a project's weekly rhythm without false-positives
    /// from stale ad-hoc activity. Configurable (constant) if tuning is needed.
    private static let activeReposLookbackDays = 7

    private let database: Database
    private let provider: any GitHubAPIProvider
    private let refresher: GitHubTokenRefresher
    private let intervalSec: TimeInterval
    private let backfillWindowDays: Int
    private let logger: Logger
    private let restartTriggerName: String

    private var loopTask: Task<Void, Never>?
    private var notifyToken: NSObjectProtocol?

    /// Phase 4.7.B-5 — in-memory cooldown gate for the daily contributions GraphQL.
    /// `"yyyy-MM-dd"` UTC; refetch fires only when the day rolls over. Reset on
    /// app restart — acceptable: at-most one redundant fetch per launch (REST
    /// `/graphql` cost ≈ negligible under the 5000pts/hr secondary limit).
    private var lastContributionsFetchDay: String?
    /// Phase 4.7.B-5 — cached value across ticks. Updated only when a fresh
    /// calendar is fetched in this tick (the cooldown gate didn't fire). Sticky:
    /// if today's day rolls over but the fetch fails, the previous value stays in
    /// `presence_state` — a non-zero false-positive is less bad than a silent drop.
    private var lastContributionsToday: Int = 0

    public init(
        database: Database,
        provider: any GitHubAPIProvider,
        refresher: GitHubTokenRefresher,
        intervalSec: TimeInterval,
        backfillWindowDays: Int,
        restartTriggerName: String = GitHubOAuthEndpoints.integrationChangedNotificationName,
        logger: Logger
    ) {
        self.database = database
        self.provider = provider
        self.refresher = refresher
        self.intervalSec = intervalSec
        self.backfillWindowDays = backfillWindowDays
        self.restartTriggerName = restartTriggerName
        self.logger = logger
    }

    public func start() {
        guard loopTask == nil else { return }
        let name = NSNotification.Name(restartTriggerName)
        notifyToken = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.kickTick() }
        }
        loopTask = Task { [weak self] in await self?.runLoop() }
        logger.info(
            "GitHubCollector started (interval=\(self.intervalSec, privacy: .public)s, backfill=\(self.backfillWindowDays, privacy: .public)d)"
        )
    }

    public func stop() async {
        loopTask?.cancel()
        await loopTask?.value
        loopTask = nil
        if let t = notifyToken {
            DistributedNotificationCenter.default().removeObserver(t)
            notifyToken = nil
        }
        logger.info("GitHubCollector stopped")
    }

    public struct TickResult: Sendable, Equatable {
        public let skipped: Bool
        public let eventsProcessed: Int
        public let cursorAdvancedMs: Int64?
    }

    @discardableResult
    public func performTick(now: Date = Date()) async -> TickResult {
        // 1. Read integration row.
        let record: IntegrationRecord?
        do {
            record = try database.readIntegration(provider: .github)
        } catch {
            logger.error("readIntegration failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        }
        guard record != nil else {
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        }

        // 2. Refresh if needed. .refreshDenied → the refresher has already done
        // deleteIntegration + UserDefaults flag + DistributedNotification.
        let refreshed: IntegrationRecord
        do {
            refreshed = try await refresher.refreshIfNeeded(now: now)
        } catch GitHubTokenRefresherError.refreshDenied(let msg) {
            logger.warning("refresh denied — GitHub disconnected: \(msg, privacy: .public)")
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        } catch {
            logger.error("refresh failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        }

        // 3. Read cursor. workspaceID per Phase 4.3 = "github:<login>" → use it directly.
        // workspaceName stores the raw login (without prefix) — this is the path /users/<login>/events.
        let sourceID = refreshed.workspaceID
        let login = refreshed.workspaceName
        let stored: CollectorOffset?
        do {
            stored = try database.readOffset(
                collectorID: CollectorID.githubPolling,
                sourceID: sourceID
            )
        } catch {
            logger.error("readOffset failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: true, eventsProcessed: 0, cursorAdvancedMs: nil)
        }
        let since: Int64? = stored?.lastModifiedMs

        // 4. Fetch.
        let batch: GitHubEventBatch
        do {
            batch = try await provider.fetchEvents(
                accessToken: refreshed.accessToken,
                login: login,
                since: since
            )
        } catch {
            logger.error("fetchEvents failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsProcessed: 0, cursorAdvancedMs: nil)
        }

        // 5. Map events.
        var events = batch.events.map { Self.makeEvent(snapshot: $0) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // 5a. Phase 4.7.B-1 — notifications pulse. Failure must NOT block events
        // tick: provider already returns `.empty(nowMs:)` on non-200 / parse failure,
        // but a network error throws — wrap in do/catch + emit an empty pulse, so
        // observability is not lost between ticks.
        let notifSummary: GitHubNotificationsSummary
        do {
            notifSummary = try await provider.fetchNotifications(accessToken: refreshed.accessToken)
        } catch {
            logger.error("fetchNotifications failed: \(String(describing: error), privacy: .public)")
            notifSummary = .empty(nowMs: nowMs)
        }
        events.append(Self.makeNotificationsPulseEvent(summary: notifSummary, nowMs: nowMs))

        // 5b. Phase 4.7.B-2 — review queue + my open PRs pulse. Each fetch is wrapped
        // in its own do/catch — independent graceful degrade. Always emit the pulses
        // even on failure (counts=0, top_repo omitted) — observability discipline.
        let reviewQueueSummary: GitHubReviewQueueSummary
        do {
            reviewQueueSummary = try await provider.fetchPRsAwaitingReview(
                accessToken: refreshed.accessToken, login: login
            )
        } catch {
            logger.error("fetchPRsAwaitingReview failed: \(String(describing: error), privacy: .public)")
            reviewQueueSummary = .empty(nowMs: nowMs)
        }
        events.append(Self.makePRAwaitingReviewCountEvent(summary: reviewQueueSummary, nowMs: nowMs))

        let myOpenPRsSummary: GitHubMyOpenPRsSummary
        do {
            myOpenPRsSummary = try await provider.fetchMyOpenPRs(
                accessToken: refreshed.accessToken, login: login
            )
        } catch {
            logger.error("fetchMyOpenPRs failed: \(String(describing: error), privacy: .public)")
            myOpenPRsSummary = .empty(nowMs: nowMs)
        }
        events.append(Self.makeMyOpenPRCountEvent(summary: myOpenPRsSummary, nowMs: nowMs))

        // 5c. Phase 4.7.B-3 — actions/runs feed for top-N most-recently-pushed repos.
        // Derive active repos from the existing `events` table — bounded fan-out N HTTP
        // calls per tick (N = `Self.activeReposCap`). DB query failure → empty list,
        // does not block the tick. `since` = nowMs - intervalSec*1000 → fetch only runs
        // initiated after last tick window (graceful approximation last-tick boundary).
        let activeReposSinceMs = nowMs - Int64(Self.activeReposLookbackDays) * 24 * 3600 * 1000
        let activeRepos: [String]
        do {
            activeRepos = try database.queryActiveGitHubRepos(
                sinceMs: activeReposSinceMs,
                limit: Self.activeReposCap
            )
        } catch {
            logger.error("queryActiveGitHubRepos failed: \(String(describing: error), privacy: .public)")
            activeRepos = []
        }
        let runsSinceMs = nowMs - Int64(intervalSec * 1000)
        let actionsRuns: [GitHubActionsRunSnapshot]
        do {
            actionsRuns = try await provider.fetchActionsRunsForActor(
                accessToken: refreshed.accessToken,
                login: login,
                repos: activeRepos,
                since: runsSinceMs
            )
        } catch {
            logger.error("fetchActionsRunsForActor failed: \(String(describing: error), privacy: .public)")
            actionsRuns = []
        }
        for run in actionsRuns {
            events.append(Self.makeActionsRunInitiatedEvent(snapshot: run))
        }

        // 5d. Phase 4.7.B-4 — check_runs aggregate per HEAD commit, push-triggered.
        // Bounded cost: K HTTP calls = K unique (repo, sha) pairs across all
        // gh_commit_pushed snapshots in this tick. Empty pushes → 0 calls (skipped
        // entirely). Iterate `batch.events` (snapshots) — preserves repo + sha
        // directly, does not rely on string lookup in the payload. Dedup via Set<String>
        // (`repo|sha`) — handles dual shape: stripped feed → 1 sha per push,
        // full webhook → N shas per push. Per-(repo,sha) failures (404 / parse)
        // → provider returns `.empty`, we still emit the pulse (observability:
        // "the HEAD commit has no/unavailable check-runs").
        var seenPairs = Set<String>()
        var pushedPairs: [(repo: String, sha: String)] = []
        for snapshot in batch.events {
            guard snapshot.eventKind == GitHubEventKindKey.commitPushed.rawValue else { continue }
            let repo = snapshot.repoFullName
            guard let sha = snapshot.sha, !sha.isEmpty, !repo.isEmpty else { continue }
            let key = "\(repo)|\(sha)"
            if seenPairs.insert(key).inserted {
                pushedPairs.append((repo: repo, sha: sha))
            }
        }
        // Latest push check-run status — collected for presence_state.github.
        // pushedPairs arrives in the order in which we iterated batch.events
        // (REST events DESC by created_at → first pair = most recent push).
        // Take the first non-nil bucket reduction; nil if there were no push events.
        var latestPushCheckStatus: String? = nil

        for pair in pushedPairs {
            let summary: GitHubCheckRunsSummary
            do {
                summary = try await provider.fetchCheckRunsForCommit(
                    accessToken: refreshed.accessToken,
                    repo: pair.repo,
                    sha: pair.sha
                )
            } catch {
                logger.error(
                    "fetchCheckRunsForCommit failed \(pair.repo, privacy: .public)/\(pair.sha, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                summary = .empty
            }
            events.append(
                Self.makeCheckRunsStatusEvent(
                    repo: pair.repo, sha: pair.sha, summary: summary, nowMs: nowMs
                ))
            if latestPushCheckStatus == nil {
                // Reduce summary → status string. Severity-ordered: failure > in_progress > success.
                if summary.failure > 0 {
                    latestPushCheckStatus = "failure"
                } else if summary.inProgress > 0 {
                    latestPushCheckStatus = "in_progress"
                } else if summary.success > 0 {
                    latestPushCheckStatus = "success"
                }
                // total=0 / only neutral → leave nil (no actionable CI signal).
            }
        }

        // 5e. Phase 4.7.B-5 — daily contributions calendar. NOT emitted as an event;
        // only a cooldown-gated update of `lastContributionsToday` for
        // presence_state.github. Cooldown — in-memory `"yyyy-MM-dd"` UTC,
        // resets on app restart (acceptable: at-most 1 redundant fetch per launch).
        let utcDayFormatter = DateFormatter()
        utcDayFormatter.calendar = Calendar(identifier: .gregorian)
        utcDayFormatter.timeZone = TimeZone(identifier: "UTC")
        utcDayFormatter.dateFormat = "yyyy-MM-dd"
        utcDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let todayString = utcDayFormatter.string(from: now)
        if lastContributionsFetchDay != todayString {
            do {
                let calendar = try await provider.fetchContributionsCalendar(
                    accessToken: refreshed.accessToken
                )
                lastContributionsToday = calendar.todayCount
                lastContributionsFetchDay = todayString
            } catch {
                logger.error("fetchContributionsCalendar failed: \(String(describing: error), privacy: .public)")
                // Cooldown does NOT advance — retry next tick same day. lastContributionsToday
                // keeps its previous value (sticky).
            }
        }

        // 6. Build presence_state.github composite snapshot.
        // ADR-010 boundary: only counts / repo identifiers / status enums.
        // No titles / bodies / message subjects enter the state JSON.
        // JSONSerialization does not accept Swift Optional — nil fields are serialized
        // as NSNull (the field is present with an explicit null value), not omitted.
        // This lets downstream readers distinguish "key absent, field not
        // tracked" from "field known, value null" — an important signal
        // for presence broadcast / merged snapshot rendering in Phase 5.
        // Track-9 T3 — viewer_login finalizes Phase 4.7.B partial. `login` already
        // in scope (passed parameter into provider.fetch* methods since OAuth bootstrap).
        // NSNull-on-empty mirrors prs_awaiting_top_repo / latest_push_check_status above
        // — distinguishes "key absent, field not tracked" from "key present, value null".
        let githubPresence: [String: Any] = [
            "notifications_unread": notifSummary.totalUnread,
            "notifications_by_reason": notifSummary.byReason,
            "prs_awaiting_my_review": reviewQueueSummary.count,
            "prs_awaiting_top_repo": reviewQueueSummary.topRepo.map { $0 as Any } ?? NSNull(),
            "my_open_prs": myOpenPRsSummary.count,
            "latest_push_check_status": latestPushCheckStatus.map { $0 as Any } ?? NSNull(),
            "contributions_today": lastContributionsToday,
            "active_repos_count": activeRepos.count,
            "viewer_login": login.isEmpty ? NSNull() as Any : login,
        ]

        // 7. Atomic write — events + offset + presence_state in one transaction.
        // If the batch is empty — the cursor does NOT move (retry next tick on the same since).
        // If the batch is non-empty — cursor = batch.cursorMs (max createdAt).
        let advancedCursor = batch.cursorMs ?? since
        let offset = CollectorOffset(
            collectorID: CollectorID.githubPolling,
            sourceID: sourceID,
            byteOffset: 0,
            inode: nil,
            size: 0,
            lastModifiedMs: advancedCursor ?? nowMs,
            updatedMs: nowMs
        )
        do {
            try database.writeEventsOffsetAndPresence(
                events,
                offset: offset,
                presence: (.github, githubPresence, nil),
                nowMs: nowMs
            )
        } catch {
            logger.error("persist failed: \(String(describing: error), privacy: .public)")
            return TickResult(skipped: false, eventsProcessed: 0, cursorAdvancedMs: nil)
        }
        if !events.isEmpty {
            logger.info(
                "tick wrote \(events.count, privacy: .public) events, cursor=\(offset.lastModifiedMs, privacy: .public)"
            )
        }
        return TickResult(
            skipped: false,
            eventsProcessed: events.count,
            cursorAdvancedMs: advancedCursor
        )
    }

    /// Phase 4.7.B-1 — `gh_notifications_pulse` state event. Emitted on EVERY tick
    /// (even with an empty inbox) — a zero count is still a signal: "the user cleared
    /// their inbox". `signal_type=.context` (state pulse, not a user action).
    /// Reasons are unpacked into top-level keys (`reason_review_requested_count`) for
    /// query-friendly access without nested JSON parsing on the read-side.
    static func makeNotificationsPulseEvent(
        summary: GitHubNotificationsSummary, nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.notificationsPulse.rawValue,
            "total_unread": String(summary.totalUnread),
            "observed_at_ms": String(nowMs),
        ]
        // Top-level fields for query-friendly access (avoid nested JSON in the payload).
        for (reason, count) in summary.byReason {
            payload["reason_\(reason)_count"] = String(count)
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-2 — `gh_pr_awaiting_review_count` state event. Emitted on every tick.
    /// `signal_type=.context` (state pulse). The `top_repo` field is omitted when `count==0`
    /// or `topRepo==nil` — distinguishes "no data" from "owner/repo:0".
    static func makePRAwaitingReviewCountEvent(
        summary: GitHubReviewQueueSummary, nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.prAwaitingReviewCount.rawValue,
            "count": String(summary.count),
            "observed_at_ms": String(nowMs),
        ]
        if let topRepo = summary.topRepo {
            payload["top_repo"] = topRepo
        }
        if let refsJSON = Self.encodePRRefs(summary.refs) {
            payload["pr_refs_json"] = refsJSON
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-3 — `gh_actions_run_initiated` action event per snapshot.
    /// `signal_type=.action` (discrete action — the user started a CI run), not `.context`.
    /// Timestamp = run's `created_at` (when GitHub registered the run start), not nowMs —
    /// synchronized with the real moment of action for downstream timeline accuracy.
    /// ADR-010: `head_commit.message` / run `name` (often equals the commit subject) /
    /// `output.title` — NOT persisted. Only public-safe metadata: workflow file slug,
    /// trigger event, status/conclusion enum, head branch.
    static func makeActionsRunInitiatedEvent(snapshot: GitHubActionsRunSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.actionsRunInitiated.rawValue,
            "run_id": String(snapshot.runID),
            "repo": snapshot.repo,
            "workflow_name": snapshot.workflowName,
            "event": snapshot.event,
            "status": snapshot.status,
            "created_at_ms": String(snapshot.createdAtMs),
        ]
        // Only non-nil fields — distinguishes "completed→success" from "in_progress" (no
        // conclusion yet) on the read-side without nullable parsing.
        if let conclusion = snapshot.conclusion {
            payload["conclusion"] = conclusion
        }
        if let branch = snapshot.headBranch {
            payload["head_branch"] = branch
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(snapshot.createdAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-4 — `gh_check_runs_status` state event per (repo, sha) pair.
    /// `signal_type=.context` (state pulse — current CI status of the HEAD commit,
    /// not a discrete user action). Timestamp = `nowMs` (when the collector observed it),
    /// not the run's `created_at` (this is an aggregate snapshot across N runs).
    /// ADR-010: neither the check-run's `name`, nor `output.title`/`output.summary`/
    /// `output.text` — the provider does not parse them and the collector does not emit them. Only
    /// 5 aggregate counts (total + 4 buckets) + repo + sha identifiers.
    static func makeCheckRunsStatusEvent(
        repo: String, sha: String, summary: GitHubCheckRunsSummary, nowMs: Int64
    ) -> RawEvent {
        let payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.checkRunsStatus.rawValue,
            "repo": repo,
            "sha": sha,
            "total": String(summary.total),
            "success": String(summary.success),
            "failure": String(summary.failure),
            "in_progress": String(summary.inProgress),
            "neutral": String(summary.neutral),
            "observed_at_ms": String(nowMs),
        ]
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Phase 4.7.B-2 — `gh_my_open_pr_count` state event. Emitted on every tick.
    /// `signal_type=.context` (state pulse).
    static func makeMyOpenPRCountEvent(
        summary: GitHubMyOpenPRsSummary, nowMs: Int64
    ) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": GitHubEventKindKey.myOpenPRCount.rawValue,
            "count": String(summary.count),
            "observed_at_ms": String(nowMs),
        ]
        if let refsJSON = Self.encodePRRefs(summary.refs) {
            payload["pr_refs_json"] = refsJSON
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000.0),
            signalType: .context,
            bundleID: nil,
            payload: payload
        )
    }

    /// Depth pass (2026-06-11) — per-PR refs (repo + number + title; titles are
    /// ADR-010 allowlisted) serialized into the pulse payload. Readers join
    /// them into the repo#number → title map so PR handles render human
    /// ("PR#64 · Home depth pass") everywhere. Empty refs → key omitted.
    static func encodePRRefs(_ refs: [GitHubPRRef]) -> String? {
        guard !refs.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(refs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// §4.3 — event kinds in the viewer's own events feed that are provably
    /// authored by the viewer (single actor). `gh_commit_pushed` is intentionally
    /// NOT here (CR-1: pushing ≠ authoring).
    static let selfAuthoredEventKinds: Set<String> = [
        GitHubEventKindKey.prOpened.rawValue,
        GitHubEventKindKey.issueOpened.rawValue,
        GitHubEventKindKey.branchCreated.rawValue,
    ]

    static func makeEvent(snapshot: GitHubEventSnapshot) -> RawEvent {
        var payload: [String: String] = [
            "source": "github",
            "event_kind": snapshot.eventKind,
            "repo": snapshot.repoFullName,
            "title": snapshot.title,
            "number": snapshot.number.map(String.init) ?? "",
            "sha": snapshot.sha ?? "",
            "branch": snapshot.branch ?? "",
        ]
        // Track AI Coworker P1 (§4.3) — self-authored attribution. This feed is
        // the viewer's OWN activity (`/users/<login>/events`), so an opened
        // PR/issue/branch here has a single actor = the viewer. Emit the explicit
        // signal the LLM egress boundary's self-authored carve-out consumes.
        // `gh_commit_pushed` is EXCLUDED (pushing ≠ authoring — a push can carry
        // merges/rebases/others' commits; per-commit author verification is a
        // follow-up). Reserved below so metadata cannot shadow it.
        if Self.selfAuthoredEventKinds.contains(snapshot.eventKind) {
            payload["authored_by_viewer"] = "true"
        }
        // Phase 4.6.A.1 — latency fields. Only non-nil → the key is present;
        // an absent key in the payload distinguishes "we don't know" from "0 seconds".
        if let cycle = snapshot.cycleSeconds {
            payload["cycle_seconds"] = String(cycle)
        }
        if let delay = snapshot.reviewDelaySeconds {
            payload["review_delay_seconds"] = String(delay)
        }
        // Phase 4.7.A — per-event-kind extension fields. Reserved baseline keys
        // ("source"/"event_kind"/"repo"/"title"/"number"/"sha"/"branch"/
        // "cycle_seconds"/"review_delay_seconds" + Track-1 D1 body/PR metadata keys)
        // cannot be overridden via metadata — guards against accidental shadowing.
        // Other keys merge in.
        if let metadata = snapshot.metadata {
            let reserved: Set<String> = [
                "source", "event_kind", "repo", "title", "number", "sha", "branch",
                "cycle_seconds", "review_delay_seconds", "authored_by_viewer",
                // Track-1 D1 — body + PR metadata keys also reserved
                Schema.EventPayloadKeys.body,
                Schema.EventPayloadKeys.bodyTruncated,
                Schema.EventPayloadKeys.attachmentsJson,
                Schema.EventPayloadKeys.filesCount,
                Schema.EventPayloadKeys.additions,
                Schema.EventPayloadKeys.deletions,
                Schema.EventPayloadKeys.requestedReviewersJson,
                Schema.EventPayloadKeys.mentionCount,
                Schema.EventPayloadKeys.linkCount,
            ]
            for (key, value) in metadata where !reserved.contains(key) {
                payload[key] = value
            }
        }
        // Track-1 D1 — body + bodyTruncated (BodyCap-applied at moat boundary).
        if let body = snapshot.body, !body.isEmpty {
            payload[Schema.EventPayloadKeys.body] = body
            if snapshot.bodyTruncated {
                payload[Schema.EventPayloadKeys.bodyTruncated] = "true"
            }
        }
        // Track-1 D1 / Phase 4.8 — PR metadata payload keys.
        if let pr = snapshot.prMetadata {
            payload[Schema.EventPayloadKeys.filesCount] = String(pr.filesCount)
            payload[Schema.EventPayloadKeys.additions] = String(pr.additions)
            payload[Schema.EventPayloadKeys.deletions] = String(pr.deletions)
            payload[Schema.EventPayloadKeys.mentionCount] = String(pr.mentionCount)
            payload[Schema.EventPayloadKeys.linkCount] = String(pr.linkCount)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(pr.requestedReviewers),
                let str = String(data: data, encoding: .utf8)
            {
                payload[Schema.EventPayloadKeys.requestedReviewersJson] = str
            }
        }
        // Track-1 D1 — attachments (release.assets + inline images from PR/comment bodies).
        if !snapshot.attachments.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(snapshot.attachments),
                let str = String(data: data, encoding: .utf8)
            {
                payload[Schema.EventPayloadKeys.attachmentsJson] = str
            }
        }
        return RawEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(snapshot.createdAtMs) / 1000.0),
            signalType: .action,
            bundleID: nil,
            payload: payload
        )
    }

    private func kickTick() async {
        await performTick()
    }

    private func runLoop() async {
        await sleep(seconds: min(intervalSec, 5))
        while !Task.isCancelled {
            await performTick()
            await sleep(seconds: intervalSec)
        }
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
