//
//  GitHubAPIProvider.swift
//  LeafCore
//
//  Phase 4.3 — protocol for REST polling the GitHub events feed.
//  Prod implementation (`GET /users/<login>/events?per_page=100`, parsing
//  PushEvent/PullRequestEvent/IssuesEvent/PullRequestReviewEvent payloads,
//  ADR-010 enforcement) lives in LeafCorePrivate (moat). The public Stub returns
//  an empty result — CI builds compile, runtime no-op.
//

import Foundation

public protocol GitHubAPIProvider: Sendable {
    /// `since` — epoch ms cursor (newest processed `created_at` from the previous tick).
    /// `nil` = bootstrap, provider decides the window itself (default: the first page of the events feed,
    /// REST events are limited to ~90 days).
    /// The provider filters client-side: `event.createdAtMs > since`. Returns batch + cursor;
    /// throws on network/parsing failures. `login` — viewer login from `GET /user`,
    /// used for the path `/users/<login>/events`.
    func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch

    /// Phase 4.7.B-1 — `GET /notifications?all=false&participating=false&per_page=50`.
    /// State pulse — what's in my inbox right now. Returns total unread count + breakdown
    /// by `reason`. Reasons we track: "review_requested", "mention", "ci_activity", "comment",
    /// "team_mention", "author", "subscribed", "manual", "state_change". Bucket "other" for unknown.
    /// Body / subject text is NOT extracted (ADR-010). The provider returns `.empty(nowMs:)` on
    /// non-200 / parse failure — graceful degradation, does not block the events tick.
    func fetchNotifications(accessToken: String) async throws -> GitHubNotificationsSummary

    /// Phase 4.7.B-2 — `GET /search/issues?q=review-requested:@me+is:open+is:pr&per_page=50`.
    /// State pulse — how many PRs are awaiting my review right now + top repo
    /// (most pending PRs). Body / title text is NOT extracted (ADR-010) — only count
    /// + repo identifier (parsed from each item's `repository_url`). The provider returns
    /// `.empty(nowMs:)` on non-200 / parse failure — graceful degradation.
    /// `login` is not used right now (`@me` query token), but reserved for a future per-org filter.
    func fetchPRsAwaitingReview(accessToken: String, login: String) async throws -> GitHubReviewQueueSummary

    /// Phase 4.7.B-2 — `GET /search/issues?q=author:@me+is:open+is:pr&per_page=50`.
    /// State pulse — how many of my PRs are open across orgs. ADR-010: we read neither title nor body;
    /// we take only the count. The provider returns `.empty(nowMs:)` on failure.
    func fetchMyOpenPRs(accessToken: String, login: String) async throws -> GitHubMyOpenPRsSummary

    /// Depth pass (2026-06-11) — point title backfill `GET /repos/{repo}/pulls/{n}`
    /// for PRs whose captured events carry no title (the stripped events feed
    /// never does, and merged PRs leave the `is:open` search pulses forever).
    /// Reads ONLY the title field (ADR-010-allowlisted); bodies never.
    /// Per-ref failures skip silently; default impl returns `[]` so existing
    /// conformers (mocks, fixtures) stay source-compatible.
    func fetchPRTitles(
        accessToken: String, refs: [(repo: String, number: Int)]
    ) async throws -> [GitHubPRRef]

    /// Phase 4.7.B-3 — `GET /repos/{owner}/{repo}/actions/runs?actor=<login>&per_page=10&created=>=<sinceISO>`.
    /// Returns Actions runs triggered by the user across all `repos` starting from `since`.
    /// `repos` — pre-computed top-N most-recently-pushed repos (the collector derives them itself
    /// via `Database.queryActiveGitHubRepos`); empty list → 0 HTTP calls, returns [].
    /// Per-repo failures (404 / 401 / non-200) — silent skip without failing the whole batch.
    /// `since` — epoch ms; the provider converts it to ISO-8601 for the query string.
    /// ADR-010: `head_commit.message`, `name` of run (often defaults to the commit subject)
    /// — NOT stored. `workflowName` (file-based: `release.yml` → "Release") — public-safe metadata.
    func fetchActionsRunsForActor(
        accessToken: String,
        login: String,
        repos: [String],
        since: Int64
    ) async throws -> [GitHubActionsRunSnapshot]

    /// Phase 4.7.B-4 — `GET /repos/{owner}/{repo}/commits/{sha}/check-runs`.
    /// Push-triggered (called only when there are `gh_commit_pushed` events in the current
    /// tick) — bounded cost: N HTTP calls = N unique (repo, sha) pairs per tick.
    /// Returns aggregate counts across 5 buckets for the HEAD commit.
    /// ADR-010: `name` of check-run, `output.title` / `output.summary` / `output.text`
    /// — NOT read. Only `status` + `conclusion` enums per run for bucketing.
    /// Returns `.empty(...)` on non-200 / parse failure / 404 (commit deleted) —
    /// graceful, does not fail the entire tick.
    func fetchCheckRunsForCommit(
        accessToken: String,
        repo: String,
        sha: String
    ) async throws -> GitHubCheckRunsSummary

    /// Phase 4.7.B-5 — GraphQL `viewer.contributionsCollection.contributionCalendar`.
    /// A single call per day (the collector gates it itself via `lastContributionsFetchDay` —
    /// an in-memory `"yyyy-MM-dd"` cooldown). Returns a 53-week heatmap + today's count
    /// for the self-UI and `presence_state.github.contributions_today`. NOT emitted as
    /// a per-tick event — this is a presence-state pulse, not an activity log.
    /// GitHub auto-includes private contributions if they're visible to self
    /// (per `Profile → Settings → Contributions`).
    /// Returns `.empty` on non-200 / GraphQL error / parse failure — graceful
    /// degradation, does not block other fetches and does not advance the cooldown (the collector
    /// retries on the next tick if the day is still current).
    func fetchContributionsCalendar(accessToken: String) async throws -> GitHubContributionsCalendar

    // MARK: - Phase Track-3 D2 — warm tier

    func fetchProjectsV2State(accessToken: String, login: String, topN: Int) async throws -> GitHubProjectsV2Snapshot
    func fetchGists(accessToken: String, login: String) async throws -> [GitHubGistSnapshot]
    func fetchRepoInvitations(accessToken: String) async throws -> [GitHubRepoInvitationSnapshot]
    func fetchCodespaces(accessToken: String) async throws -> [GitHubCodespaceSnapshot]
    func fetchIssueReactions(accessToken: String, owner: String, repo: String, issueNumber: Int) async throws -> GitHubIssueReactionsSnapshot

    // MARK: - Phase Track-3 D2 — cold tier

    func fetchStarredRepos(accessToken: String, login: String) async throws -> [GitHubStarredRepoSnapshot]
    func fetchWatchedRepos(accessToken: String, login: String) async throws -> [GitHubWatchedRepoSnapshot]
    func fetchSecretScanningAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot]
    func fetchCodeScanningAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot]
    func fetchDependabotAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot]
    func fetchOrganizations(accessToken: String) async throws -> [GitHubOrgSnapshot]
    func fetchOrgAuditLog(accessToken: String, org: String, since: Int64?) async throws -> GitHubOrgAuditLogBatch
}

extension GitHubAPIProvider {
    /// Default no-op — keeps existing conformers (mocks, fixtures, stubs)
    /// source-compatible; the production moat provider overrides.
    public func fetchPRTitles(
        accessToken: String, refs: [(repo: String, number: Int)]
    ) async throws -> [GitHubPRRef] { [] }
}

/// The result of a single REST fetch. `cursorMs` — `max(createdAt)` across `events`
/// (REST events feed DESC by `created_at` → `events.first?.createdAtMs`),
/// or `nil` if the batch is empty (cursor doesn't advance, retry next tick).
/// Mirroring `LinearIssueBatch` — schema-aligned timestamp cursor instead of eventID-as-cursor
/// (collector_offsets.last_modified_ms — strictly INTEGER).
public struct GitHubEventBatch: Sendable, Hashable {
    public let events: [GitHubEventSnapshot]
    public let cursorMs: Int64?

    public init(events: [GitHubEventSnapshot], cursorMs: Int64?) {
        self.events = events
        self.cursorMs = cursorMs
    }

    public static let empty = GitHubEventBatch(events: [], cursorMs: nil)
}

/// Phase Track-1 D1 — PR-specific numeric metadata captured from
/// `payload.pull_request` REST fields. Bridges Phase 4.8 carry-over metrics
/// (files_count / additions / deletions / requested_reviewers) + body-derived
/// counts (mention_count / link_count) across the LeafCorePrivate moat.
///
/// ADR-010 §6 amendment: PR body captured on-device only; relay never sees bodies.
/// The counts here are derived from the raw body BEFORE BodyCap truncation to
/// preserve accurate signal; requestedReviewers is anonymized login array (no PII).
public struct PRMetadata: Codable, Sendable, Hashable {
    public let filesCount: Int
    public let additions: Int
    public let deletions: Int
    /// Requested reviewer logins. Public-safe: GitHub logins are non-PII by design.
    public let requestedReviewers: [String]
    public let mentionCount: Int
    public let linkCount: Int

    public init(
        filesCount: Int,
        additions: Int,
        deletions: Int,
        requestedReviewers: [String],
        mentionCount: Int,
        linkCount: Int
    ) {
        self.filesCount = filesCount
        self.additions = additions
        self.deletions = deletions
        self.requestedReviewers = requestedReviewers
        self.mentionCount = mentionCount
        self.linkCount = linkCount
    }
}

/// A single event in the batch — public-safe metadata (whitepaper Section 6 Action signal).
/// Track-1 D1 §6 amendment: PR body / issue-comment body / commit full message
/// captured on-device (SQLCipher); relay never sees. `body` field = already
/// BodyCap-truncated at the LeafCorePrivate moat boundary.
public struct GitHubEventSnapshot: Sendable, Hashable {
    /// REST events `id` — used for parser-side dedup within a single fetch
    /// (cursor-by-timestamp is imperfect for events with identical `created_at`).
    public let eventID: String
    /// Canonical kind after mapping raw GitHub `type` + `payload.action`.
    /// Phase 4.6 baseline: "gh_commit_pushed" | "gh_pr_opened" | "gh_pr_merged" | "gh_pr_closed"
    /// | "gh_issue_opened" | "gh_issue_closed" | "gh_pr_review_submitted".
    /// Phase 4.7.A additions: "gh_pr_review_comment_authored" | "gh_issue_comment_authored"
    /// | "gh_release_published" | "gh_branch_created" | "gh_branch_deleted" | "gh_tag_created"
    /// | "gh_discussion_authored" | "gh_discussion_comment_authored".
    /// Track-9 T3 additions: "gh_pr_review_requested" | "gh_pr_review_request_removed"
    /// (PR review request lifecycle, outbound only — viewer asked others to review).
    public let eventKind: String
    /// "owner/name" — self-authored repo identifier, public-safe.
    public let repoFullName: String
    /// Commit subject (first line only) for gh_commit_pushed; PR title; issue title.
    public let title: String
    /// PR/issue/discussion number; `nil` for gh_commit_pushed / gh_pr_review_submitted without issue context.
    public let number: Int?
    /// Commit SHA (short or full) for PushEvent; `nil` for non-push.
    public let sha: String?
    /// Branch ref (e.g. "main") for PushEvent / gh_branch_created / gh_branch_deleted.
    public let branch: String?
    /// Epoch ms — becomes the cursor for the next polling tick (max `createdAtMs`
    /// goes into `GitHubEventBatch.cursorMs` → `collector_offsets.last_modified_ms`).
    public let createdAtMs: Int64
    /// Phase 4.6.A.1 — for `gh_pr_merged`: `closed_at - created_at` in seconds. `nil` for
    /// other eventKinds or if timestamps are missing from the payload (clock skew clamped to 0).
    public let cycleSeconds: Int?
    /// Phase 4.6.A.1 — for `gh_pr_review_submitted`: `review.submitted_at - pull_request.created_at`
    /// in seconds. `nil` for other eventKinds or missing timestamps.
    public let reviewDelaySeconds: Int?
    /// Phase 4.7.A — extension slot for new event_kinds with per-kind payload fields
    /// (`action`, `tag_name`, `category`, `comment_id`, `is_pull_request`,
    /// `linked_linear_id`). `nil` or empty dict — we don't emit keys in the payload (distinguishes
    /// "don't know" from an empty value). Existing baseline event_kinds leave it nil.
    public let metadata: [String: String]?
    /// Phase Track-1 D1 — already BodyCap-truncated body text (PR body / comment text /
    /// full commit message). Moat boundary: truncation applied inside LeafCorePrivate.
    /// `nil` = body not available for this event_kind (e.g. gh_branch_created, release events).
    public let body: String?
    /// Phase Track-1 D1 — true if `body` was truncated by BodyCap at the moat boundary.
    /// Architectural workaround: LeafCore cannot import LeafCorePrivate, so the truncation
    /// flag is bridged via this field rather than re-computing in the collector.
    public let bodyTruncated: Bool
    /// Phase Track-1 D1 / Phase 4.8 carry-over — PR-specific numeric metadata.
    /// `nil` for non-PR events (gh_commit_pushed / gh_issue_comment_authored / gh_release_published etc).
    public let prMetadata: PRMetadata?
    /// Phase Track-1 D1 — attachments for this event. For gh_release_published: release.assets[].
    /// For PR/comment events: inline images parsed from the body. Empty array = no attachments.
    public let attachments: [AttachmentMeta]

    public init(
        eventID: String,
        eventKind: String,
        repoFullName: String,
        title: String,
        number: Int?,
        sha: String?,
        branch: String?,
        createdAtMs: Int64,
        cycleSeconds: Int? = nil,
        reviewDelaySeconds: Int? = nil,
        metadata: [String: String]? = nil,
        body: String? = nil,
        bodyTruncated: Bool = false,
        prMetadata: PRMetadata? = nil,
        attachments: [AttachmentMeta] = []
    ) {
        self.eventID = eventID
        self.eventKind = eventKind
        self.repoFullName = repoFullName
        self.title = title
        self.number = number
        self.sha = sha
        self.branch = branch
        self.createdAtMs = createdAtMs
        self.cycleSeconds = cycleSeconds
        self.reviewDelaySeconds = reviewDelaySeconds
        self.metadata = metadata
        self.body = body
        self.bodyTruncated = bodyTruncated
        self.prMetadata = prMetadata
        self.attachments = attachments
    }
}

/// Phase 4.7.B-1 — summary of a single `/notifications` fetch. State snapshot (not an events log):
/// `totalUnread` = what's sitting in the inbox right now, `byReason` — breakdown.
/// Included in the events feed as a single `gh_notifications_pulse` event with
/// `signal_type=.context` (not `.action` — this is a state pulse, not a user action).
public struct GitHubNotificationsSummary: Sendable, Hashable {
    /// Sum of unread notifications across all reasons. `byReason.values.sum()`,
    /// but stored independently in case parsing of the `other` bucket lags behind the raw count.
    public let totalUnread: Int
    /// Reason → count. Only non-zero buckets (the parser doesn't emit a key if 0).
    public let byReason: [String: Int]
    /// `now` from the Agent at fetch time — used as `observed_at_ms` in the event payload.
    public let observedAtMs: Int64

    public init(totalUnread: Int, byReason: [String: Int], observedAtMs: Int64) {
        self.totalUnread = totalUnread
        self.byReason = byReason
        self.observedAtMs = observedAtMs
    }

    /// Used on non-200 / parse failure / collector graceful degradation.
    /// `observedAtMs` is still populated — because a pulse event with total_unread=0
    /// is semantically valid ("inbox empty at moment N").
    public static func empty(nowMs: Int64) -> GitHubNotificationsSummary {
        GitHubNotificationsSummary(totalUnread: 0, byReason: [:], observedAtMs: nowMs)
    }
}

/// Depth pass (2026-06-11) — per-PR reference carried by the 4.7.B search
/// summaries. PR titles are ADR-010 allowlisted (Action signal: "commit
/// message, issue title, branch name"); the original count-only shape was
/// over-conservative and left every UI surface with bare "PR#64" handles
/// because the stripped events feed never carries a title.
public struct GitHubPRRef: Sendable, Hashable, Codable {
    /// "owner/repo".
    public let repo: String
    public let number: Int
    public let title: String

    public init(repo: String, number: Int, title: String) {
        self.repo = repo
        self.number = number
        self.title = title
    }
}

/// Phase 4.7.B-2 — summary `/search/issues?q=review-requested:@me+is:open+is:pr`.
/// State snapshot: the number of PRs awaiting my review + top repo (most pending PRs)
/// for the self-UI. Emitted as a `gh_pr_awaiting_review_count` event with
/// `signal_type=.context`. Bodies are never read (ADR-010); titles are
/// allowlisted and ride in `refs` (depth pass).
public struct GitHubReviewQueueSummary: Sendable, Hashable {
    /// Sum of PRs awaiting my review (search.issues `total_count` or len(items[])).
    public let count: Int
    /// "owner/repo" with the most-pending PRs. `nil` if `count == 0`.
    /// On a tie — we take the first one encountered (search.issues order by best-match).
    public let topRepo: String?
    /// `now` from the Agent at fetch time. Used as `observed_at_ms` in the payload.
    public let observedAtMs: Int64
    /// Per-PR refs (repo + number + title), capped at the provider. Default
    /// `[]` keeps pre-depth-pass callsites compiling.
    public let refs: [GitHubPRRef]

    public init(count: Int, topRepo: String?, observedAtMs: Int64, refs: [GitHubPRRef] = []) {
        self.count = count
        self.topRepo = topRepo
        self.observedAtMs = observedAtMs
        self.refs = refs
    }

    /// Used on non-200 / parse failure / graceful degradation. `count=0` +
    /// `topRepo=nil` — semantically valid ("review queue empty at moment N").
    public static func empty(nowMs: Int64) -> GitHubReviewQueueSummary {
        GitHubReviewQueueSummary(count: 0, topRepo: nil, observedAtMs: nowMs)
    }
}

/// Phase 4.7.B-2 — summary `/search/issues?q=author:@me+is:open+is:pr`.
/// State snapshot: the number of my open PRs across orgs. Emitted as a
/// `gh_my_open_pr_count` event, `signal_type=.context`. Bodies are never read
/// (ADR-010); titles are allowlisted and ride in `refs` (depth pass).
public struct GitHubMyOpenPRsSummary: Sendable, Hashable {
    /// Sum of my open PRs.
    public let count: Int
    /// `now` from the Agent at fetch time. Used as `observed_at_ms` in the payload.
    public let observedAtMs: Int64
    /// Per-PR refs (repo + number + title), capped at the provider. Default
    /// `[]` keeps pre-depth-pass callsites compiling.
    public let refs: [GitHubPRRef]

    public init(count: Int, observedAtMs: Int64, refs: [GitHubPRRef] = []) {
        self.count = count
        self.observedAtMs = observedAtMs
        self.refs = refs
    }

    /// Used on non-200 / parse failure / graceful degradation.
    public static func empty(nowMs: Int64) -> GitHubMyOpenPRsSummary {
        GitHubMyOpenPRsSummary(count: 0, observedAtMs: nowMs)
    }
}

/// Phase 4.7.B-3 — a single `workflow_runs[]` element of `/repos/{owner}/{repo}/actions/runs`.
/// Public-safe metadata (whitepaper Section 6 Action signal). ADR-010: neither
/// `head_commit.message`, nor `name` of run (often equals commit subject), nor
/// `output.title`/`output.summary` — are stored. `workflowName` derived from the
/// workflow file slug (e.g. `release.yml` → "Release") — public-safe.
public struct GitHubActionsRunSnapshot: Sendable, Hashable {
    /// The run's REST `id` field — used for dedup within a single fetch.
    public let runID: Int64
    /// "owner/repo" — public-safe identifier.
    public let repo: String
    /// File-based workflow name (slug → display name). NOT the run-name (that often
    /// equals the commit subject — ADR-010 unsafe).
    public let workflowName: String
    /// Trigger event: "push" | "pull_request" | "schedule" | "workflow_dispatch" | ...
    public let event: String
    /// "queued" | "in_progress" | "completed".
    public let status: String
    /// "success" | "failure" | "cancelled" | "skipped" | nil if not completed.
    public let conclusion: String?
    /// Epoch ms of `created_at` (when the run was initiated).
    public let createdAtMs: Int64
    /// Branch ref (e.g. "main"). May be absent for some trigger types.
    public let headBranch: String?

    public init(
        runID: Int64,
        repo: String,
        workflowName: String,
        event: String,
        status: String,
        conclusion: String?,
        createdAtMs: Int64,
        headBranch: String?
    ) {
        self.runID = runID
        self.repo = repo
        self.workflowName = workflowName
        self.event = event
        self.status = status
        self.conclusion = conclusion
        self.createdAtMs = createdAtMs
        self.headBranch = headBranch
    }
}

/// Phase 4.7.B-4 — aggregate check-runs summary for a single HEAD commit
/// (`/repos/{owner}/{repo}/commits/{sha}/check-runs`). State pulse — current
/// CI status of HEAD after a push. ADR-010: the provider reads only
/// `status` + `conclusion` enums per run, not `name` / `output.*` / `details_url`.
/// `total` = sum across all 5 buckets = response `total_count`.
public struct GitHubCheckRunsSummary: Sendable, Hashable {
    /// Sum of check-runs across all buckets. Equivalent to response `total_count`.
    public let total: Int
    /// `status="completed"` + `conclusion="success"` bucket.
    public let success: Int
    /// `status="completed"` + `conclusion ∈ {"failure","timed_out","action_required","startup_failure"}`.
    public let failure: Int
    /// `status ∈ {"queued","in_progress"}` — runs still executing.
    public let inProgress: Int
    /// `status="completed"` + `conclusion ∈ {"skipped","cancelled","stale","neutral"}` —
    /// non-failing terminal states (skipped CI matrix legs, cancelled by user, stale checks).
    public let neutral: Int

    public init(total: Int, success: Int, failure: Int, inProgress: Int, neutral: Int) {
        self.total = total
        self.success = success
        self.failure = failure
        self.inProgress = inProgress
        self.neutral = neutral
    }

    /// Used on non-200 / parse failure / 404 / network error — graceful degradation.
    /// `total=0` is still semantically valid ("the HEAD commit has no check-runs").
    public static let empty = GitHubCheckRunsSummary(
        total: 0, success: 0, failure: 0, inProgress: 0, neutral: 0
    )
}

/// Phase 4.7.B-5 — GraphQL `viewer.contributionsCollection.contributionCalendar`
/// snapshot. Daily fetch (collector cooldown), used for the self-UI heatmap +
/// `presence_state.github.contributions_today`. ADR-010-safe — these are aggregate
/// counts per day (no titles / bodies / repo-level breakdown).
public struct GitHubContributionsCalendar: Sendable, Hashable {
    /// Aggregate over fetched range (≈ last 365 days). Equivalent to
    /// `contributionCalendar.totalContributions` in the GraphQL response.
    public let totalContributions: Int
    /// Today's count — derived from `weeks[].contributionDays[]` where
    /// `date == today` in UTC. `0` if today isn't in the response yet (the calendar
    /// may not contain today's day for recent timezone shifts) or
    /// on the `.empty` fallback.
    public let todayCount: Int
    /// Last 53 weeks by descending age (oldest first, as GitHub returns them).
    /// Used for self-UI heatmap rendering — the collector does not write it to
    /// `presence_state` (the raw heatmap lives in memory + UI cache, not in SQLCipher).
    public let weeks: [Week]

    public struct Week: Sendable, Hashable {
        public let days: [Day]
        public init(days: [Day]) { self.days = days }
    }
    public struct Day: Sendable, Hashable {
        /// "yyyy-MM-dd" in UTC (GitHub returns ISO date strings).
        public let date: String
        public let count: Int
        /// 0..4 — bucket level; 0 = `NONE`, 4 = `FOURTH_QUARTILE`.
        public let level: Int
        public init(date: String, count: Int, level: Int) {
            self.date = date
            self.count = count
            self.level = level
        }
    }

    public init(totalContributions: Int, todayCount: Int, weeks: [Week]) {
        self.totalContributions = totalContributions
        self.todayCount = todayCount
        self.weeks = weeks
    }

    /// Used on non-200 / GraphQL error / parse failure / network error.
    /// `todayCount=0` is semantically correct ("the calendar is unavailable right now,
    /// presence_state.contributions_today keeps its previous value until the next day").
    public static let empty = GitHubContributionsCalendar(
        totalContributions: 0, todayCount: 0, weeks: []
    )
}

/// Stub for CI / dev-without-moat builds. Never makes an HTTP call, returns
/// `.empty` — the GitHubCollector tick passes as a no-op.
public struct StubGitHubAPIProvider: GitHubAPIProvider {
    public init() {}
    public func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch {
        .empty
    }
    public func fetchNotifications(accessToken: String) async throws -> GitHubNotificationsSummary {
        .empty(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }
    public func fetchPRsAwaitingReview(accessToken: String, login: String) async throws -> GitHubReviewQueueSummary {
        .empty(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }
    public func fetchMyOpenPRs(accessToken: String, login: String) async throws -> GitHubMyOpenPRsSummary {
        .empty(nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }
    public func fetchActionsRunsForActor(
        accessToken: String,
        login: String,
        repos: [String],
        since: Int64
    ) async throws -> [GitHubActionsRunSnapshot] {
        []
    }
    public func fetchCheckRunsForCommit(
        accessToken: String,
        repo: String,
        sha: String
    ) async throws -> GitHubCheckRunsSummary {
        .empty
    }
    public func fetchContributionsCalendar(accessToken: String) async throws -> GitHubContributionsCalendar {
        .empty
    }

    // MARK: - Phase Track-3 D2 — warm tier

    public func fetchProjectsV2State(accessToken: String, login: String, topN: Int) async throws -> GitHubProjectsV2Snapshot {
        .empty
    }
    public func fetchGists(accessToken: String, login: String) async throws -> [GitHubGistSnapshot] {
        []
    }
    public func fetchRepoInvitations(accessToken: String) async throws -> [GitHubRepoInvitationSnapshot] {
        []
    }
    public func fetchCodespaces(accessToken: String) async throws -> [GitHubCodespaceSnapshot] {
        []
    }
    public func fetchIssueReactions(accessToken: String, owner: String, repo: String, issueNumber: Int) async throws -> GitHubIssueReactionsSnapshot {
        .empty(owner: owner, repo: repo, issueNumber: issueNumber, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
    }

    // MARK: - Phase Track-3 D2 — cold tier

    public func fetchStarredRepos(accessToken: String, login: String) async throws -> [GitHubStarredRepoSnapshot] {
        []
    }
    public func fetchWatchedRepos(accessToken: String, login: String) async throws -> [GitHubWatchedRepoSnapshot] {
        []
    }
    public func fetchSecretScanningAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot] {
        []
    }
    public func fetchCodeScanningAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot] {
        []
    }
    public func fetchDependabotAlerts(accessToken: String, owner: String, repo: String) async throws -> [GitHubSecurityAlertSnapshot] {
        []
    }
    public func fetchOrganizations(accessToken: String) async throws -> [GitHubOrgSnapshot] {
        []
    }
    public func fetchOrgAuditLog(accessToken: String, org: String, since: Int64?) async throws -> GitHubOrgAuditLogBatch {
        .empty
    }
}
