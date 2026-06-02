//
//  LinearGraphQLProvider.swift
//  LeafCore
//
//  Phase 4.2 — protocol for GraphQL polling Linear (issues filter updatedAt).
//  Prod implementation (paginated + retry + complexity budget) lives in
//  LeafCorePrivate (moat). Public Stub returns an empty result —
//  CI builds compile, runtime no-op.
//

import Foundation

public protocol LinearGraphQLProvider: Sendable {
    /// `since` — epoch ms cursor (newest processed `updatedAt` from the previous tick).
    /// `nil` = bootstrap: provider decides the window itself (default 7d backwards).
    /// Returns batch + cursor; throws on network/parsing failures.
    func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch
    /// Phase Track-3 D1 — warm tier (15m) state sweep: notifications + cycles
    /// + subscribed issues. Single GraphQL call combining 3 top-level fields.
    /// `cursors.notificationsSince` / `cursors.cyclesSince` nil → 7-day backfill.
    func fetchWarmState(accessToken: String, cursors: LinearWarmCursors) async throws -> LinearWarmBatch
    /// Phase Track-3 D1 — cold tier (4am local) state sweep: roadmaps +
    /// customViews + projectMemberships. Single GraphQL call. No cursor —
    /// snapshot diff on the collector side.
    func fetchColdState(accessToken: String) async throws -> LinearColdBatch
}

/// Result of a single GraphQL fetch. `cursorMs` — `max(updatedAt)` across `issues`,
/// or `nil` if the batch is empty (cursor does not advance, retry on the next tick).
/// Phase 4.6.B — additive `transitions` field: my status transitions from the nested
/// IssueHistory fragment, after client-side filter (the Linear API does not support
/// an `actor.isMe` filter on the history connection).
/// Phase 4.7.B — additive `workload` field: viewer's currently-`started` assigned
/// issues snapshot. Single page (≤50 issues per user typically), single HTTP call —
/// piggy-back on the existing `fetchIssues` query via the `viewer.assignedIssues` root field.
/// Phase 4.7.B (B-7) — additive `cycles` field: viewer's teams current active cycle
/// progress. Up to 5 teams (cap per design budget), single HTTP call — piggy-back
/// on the existing `fetchIssues` query via the `viewer.teams.activeCycle` block.
public struct LinearIssueBatch: Sendable, Hashable {
    public let issues: [LinearIssueSnapshot]
    public let cursorMs: Int64?
    public let transitions: [LinearStateTransitionSnapshot]
    public let workload: LinearAssignedWorkloadSnapshot
    public let cycles: LinearCycleSnapshot
    /// Phase 4.7.C — additive transition flavors (priority/labels/assignee/cycle/estimate).
    /// All piggy-back on the same `Issue.history` connection — no extra HTTP calls.
    /// Each array is independent: one history entry may produce 0+ snaps of different
    /// flavors (priority change + label add + assignee bucket in one mutation).
    public let priorityTransitions: [LinearPriorityTransitionSnapshot]
    public let labelTransitions: [LinearLabelTransitionSnapshot]
    public let assigneeTransitions: [LinearAssigneeTransitionSnapshot]
    public let cycleTransitions: [LinearCycleTransitionSnapshot]
    public let estimateTransitions: [LinearEstimateTransitionSnapshot]
    /// Phase 4.7.C — ProjectUpdate authored snaps (separate top-level Linear type,
    /// piggy-back fragment in the same query). Empty if the provider degraded
    /// or the user has no updates in the window.
    public let projectUpdates: [LinearProjectUpdateSnapshot]
    /// Phase 4.7.C — Linear Document snaps (skeleton). Empty when there is no
    /// feature support or the user has zero activity.
    public let documents: [LinearDocumentSnapshot]
    /// Phase 4.7.C — Initiatives membership snapshot (skeleton). Empty when there is
    /// no feature support / on legacy plans.
    public let initiatives: [LinearInitiativeSnapshot]
    /// Phase Track-3 D1 — hot piggy-back additions. Each array is additive on
    /// existing `fetchIssues` GraphQL query (no extra HTTP calls). Defaults are
    /// `[]` so all pre-Track-3 callers stay compile-clean.
    public let commentReactions: [LinearCommentReactionSnapshot]
    public let relationAdditions: [LinearRelationSnapshot]
    public let relationRemovals: [LinearRelationSnapshot]
    public let triagePickedUp: [LinearTriageTransitionSnapshot]
    public let triageResolved: [LinearTriageTransitionSnapshot]
    /// Track-9 T2 — Linear organization `urlKey` from `viewer.organization { urlKey }`
    /// fragment in LeafPoll. Cached in `LinearCollector` actor state; used by
    /// `makeCommentToMeEvent` parser to compose `linear_issue_url` payload field
    /// (`https://linear.app/{slug}/issue/{key}`). `nil` on cold-first-tick before
    /// the viewer fetch lands or on Linear free-tier accounts that return null org.
    public let workspaceSlug: String?

    public init(
        issues: [LinearIssueSnapshot],
        cursorMs: Int64?,
        transitions: [LinearStateTransitionSnapshot] = [],
        workload: LinearAssignedWorkloadSnapshot = .empty,
        cycles: LinearCycleSnapshot = .empty,
        priorityTransitions: [LinearPriorityTransitionSnapshot] = [],
        labelTransitions: [LinearLabelTransitionSnapshot] = [],
        assigneeTransitions: [LinearAssigneeTransitionSnapshot] = [],
        cycleTransitions: [LinearCycleTransitionSnapshot] = [],
        estimateTransitions: [LinearEstimateTransitionSnapshot] = [],
        projectUpdates: [LinearProjectUpdateSnapshot] = [],
        documents: [LinearDocumentSnapshot] = [],
        initiatives: [LinearInitiativeSnapshot] = [],
        commentReactions: [LinearCommentReactionSnapshot] = [],
        relationAdditions: [LinearRelationSnapshot] = [],
        relationRemovals: [LinearRelationSnapshot] = [],
        triagePickedUp: [LinearTriageTransitionSnapshot] = [],
        triageResolved: [LinearTriageTransitionSnapshot] = [],
        workspaceSlug: String? = nil
    ) {
        self.issues = issues
        self.cursorMs = cursorMs
        self.transitions = transitions
        self.workload = workload
        self.cycles = cycles
        self.priorityTransitions = priorityTransitions
        self.labelTransitions = labelTransitions
        self.assigneeTransitions = assigneeTransitions
        self.cycleTransitions = cycleTransitions
        self.estimateTransitions = estimateTransitions
        self.projectUpdates = projectUpdates
        self.documents = documents
        self.initiatives = initiatives
        self.commentReactions = commentReactions
        self.relationAdditions = relationAdditions
        self.relationRemovals = relationRemovals
        self.triagePickedUp = triagePickedUp
        self.triageResolved = triageResolved
        self.workspaceSlug = workspaceSlug
    }

    public static let empty = LinearIssueBatch(
        issues: [], cursorMs: nil
    )
}

/// Phase 4.7.B — snapshot of my assigned `started` issues (current workload pulse).
/// Substrate for the Phase 5 broadcast (presence_state.linear) and MCP `get_workload_pulse`.
/// Source: `viewer.assignedIssues(filter: { state: { type: { in: [started] } } })`,
/// single page first:50.
///
/// ADR-010 — title / description / body are NOT requested. Public-safe metadata only:
/// counts, priority enum (Linear's int), identifier (self-authored label), updatedAt.
public struct LinearAssignedWorkloadSnapshot: Sendable, Hashable {
    /// How many issues with `state.type == "started"` are assigned to me right now.
    /// 0 if I have nothing in-flight.
    public let startedCount: Int
    /// Linear priority enum: 1=urgent, 2=high, 3=normal, 4=low. `nil` if:
    /// (a) startedCount == 0, (b) all issues have priority == 0 ("no priority" in Linear).
    /// Minimum across issues — the most urgent priority in the current workload.
    public let topPriority: Int?
    /// Identifier (e.g. "LEA-123") of the issue with the most recent `updatedAt` in the started bucket.
    /// `nil` if startedCount == 0.
    public let lastTouchedIdentifier: String?
    /// Epoch ms of that same most-recent `updatedAt`.
    /// `nil` if startedCount == 0.
    public let lastTouchedTs: Int64?

    public init(
        startedCount: Int,
        topPriority: Int?,
        lastTouchedIdentifier: String?,
        lastTouchedTs: Int64?
    ) {
        self.startedCount = startedCount
        self.topPriority = topPriority
        self.lastTouchedIdentifier = lastTouchedIdentifier
        self.lastTouchedTs = lastTouchedTs
    }

    public static let empty = LinearAssignedWorkloadSnapshot(
        startedCount: 0,
        topPriority: nil,
        lastTouchedIdentifier: nil,
        lastTouchedTs: nil
    )
}

/// Phase 4.7.B (B-7) — per-team current active cycle progress snapshot.
/// One of the user's ≤5 teams (`viewer.teams(first: 5).nodes[].activeCycle`).
/// Source: `viewer.teams.activeCycle.{scopeHistory, completedScopeHistory, progress}`.
///
/// ADR-010 — cycle.description / cycle goals / any long-form text are NOT requested
/// and NOT parsed. Only public-safe metadata: cycle id (internal), self-authored
/// cycle name (e.g. "Sprint 42"), scope counts, days remaining, completed pct.
public struct LinearTeamCycleSnapshot: Sendable, Hashable {
    /// Linear's internal team UUID. Public-safe metadata (not PII).
    public let teamID: String
    /// Self-authored team name (e.g. "Engineering", "Leaf"). Per Section 6 — OK.
    public let teamName: String
    /// Linear's internal cycle UUID.
    public let cycleID: String
    /// Self-authored cycle name (e.g. "Sprint 42", "Cycle 7"). Per Section 6 — OK.
    public let cycleName: String
    /// Cycle start (epoch ms).
    public let startsAtMs: Int64
    /// Cycle end (epoch ms).
    public let endsAtMs: Int64
    /// 0-100. Derived from `completedScopeHistory.last / scopeHistory.last * 100`,
    /// fallback to `progress * 100` if histories missing/empty.
    public let completedPct: Double
    /// `(endsAtMs - nowMs) / 86_400_000` floored, clamped to 0 if the cycle has already ended.
    public let daysRemaining: Int
    /// Total scope (`scopeHistory.last` rounded to Int). 0 if scope history is empty.
    public let scopeCount: Int

    public init(
        teamID: String,
        teamName: String,
        cycleID: String,
        cycleName: String,
        startsAtMs: Int64,
        endsAtMs: Int64,
        completedPct: Double,
        daysRemaining: Int,
        scopeCount: Int
    ) {
        self.teamID = teamID
        self.teamName = teamName
        self.cycleID = cycleID
        self.cycleName = cycleName
        self.startsAtMs = startsAtMs
        self.endsAtMs = endsAtMs
        self.completedPct = completedPct
        self.daysRemaining = daysRemaining
        self.scopeCount = scopeCount
    }
}

/// Phase 4.7.B (B-7) — aggregate snapshot of all the user's teams with an active cycle.
/// Teams without an `activeCycle` (Linear returns null) are skipped — the `teams` array
/// contains only teams where a cycle is in-flight. Empty `teams` = nothing in-flight,
/// downstream LinearCollector emits nothing (no cycle events).
public struct LinearCycleSnapshot: Sendable, Hashable {
    /// Per-team snapshot of the active cycle. Up to 5 entries (provider cap).
    public let teams: [LinearTeamCycleSnapshot]
    /// Snapshot capture timestamp (epoch ms). 0 if the snapshot is empty (`.empty`).
    public let observedAtMs: Int64

    public init(teams: [LinearTeamCycleSnapshot], observedAtMs: Int64) {
        self.teams = teams
        self.observedAtMs = observedAtMs
    }

    public static let empty = LinearCycleSnapshot(teams: [], observedAtMs: 0)
}

/// Phase Track-1 D1 — captured Linear issue comment body for FTS5 / decision
/// detection. ADR-010 §6 amended — bodies allowed on-device, never in relay.
public struct LinearCommentBody: Codable, Sendable, Hashable {
    public let commentID: String
    public let createdAtMs: Int64
    public let body: String

    public init(commentID: String, createdAtMs: Int64, body: String) {
        self.commentID = commentID
        self.createdAtMs = createdAtMs
        self.body = body
    }
}

/// One issue in the batch — public-safe metadata (whitepaper Section 6 Action signal).
/// Track-1 D1: description + comment bodies + attachment metadata added (on-device only).
public struct LinearIssueSnapshot: Sendable, Hashable {
    /// e.g. "LEA-123" — self-authored label, public-safe.
    public let issueKey: String
    /// Self-authored, OK per Section 6.
    public let title: String
    /// Workflow state name, e.g. "In Progress".
    public let status: String
    /// Project name; "" if the issue is not in a project.
    public let project: String
    /// Team key, e.g. "LEA".
    public let teamKey: String
    /// Epoch ms — becomes the cursor for the next polling tick.
    public let updatedAtMs: Int64
    /// Phase 4.6.A.2 — `completedAt - startedAt` in seconds for issues completed
    /// within the polling window (the provider dedups so the sample is not recounted on
    /// post-completion activity). `nil` if: (a) the issue is not completed,
    /// (b) startedAt is missing, (c) completedAt is earlier than the polling cursor.
    /// Clock skew clamped to 0.
    public let completionSeconds: Int?
    /// Phase 4.7.A — count of my comments on this issue that fall within the tick window
    /// (`createdAt > effectiveSince`, actor filtered by `user.id == viewer.id`,
    /// applied client-side in the parser). 0 if there were no comments of mine.
    /// ADR-010: bodies are NOT requested — only id + createdAt + user.id for the filter.
    public let commentCountInWindow: Int
    /// Track-9 T2 — discriminator counterpart to `commentCountInWindow`: count comments
    /// authored BY OTHERS (`comment.user.id != viewer.id`) on this viewer-touched issue
    /// within the polling window. Substrate seed for the `linear_comment_authored_to_me`
    /// sibling event_kind. 0 if there were no comments-to-me. ADR-010: same allowlist —
    /// only id + createdAt + user.id for the filter, bodies won't trip the provider.
    public let incomingCommentCount: Int
    /// Phase 4.7.B (B-8) — counts of GitHub PR attachments on this issue, derived
    /// from the `Issue.attachments(first: 10)` block by the URL parser. 0 if no
    /// attachment matched the GitHub PR pattern (or nothing was attached at all).
    public let linkedGitHubPRCount: Int
    /// Phase 4.7.B (B-8) — most-frequent `<owner>/<repo>` among the GitHub PR attachments
    /// on this issue. `nil` if linkedGitHubPRCount==0. Tie-break — lex-smallest
    /// repo on equal counts (deterministic across test fixtures + production).
    public let linkedGitHubTopRepo: String?
    /// Phase 4.7.B (B-8) — counts Slack permalink attachments (matched
    /// `https://<workspace>.slack.com/archives/<channel>/p<ts>` pattern).
    /// 0 if no attachment matched. ADR-010: only the URL structure is parsed,
    /// message text / preview are not requested.
    public let linkedSlackMessageCount: Int
    /// Phase 4.7.B (B-8) — total count of attachments on the issue (of all kinds: GitHub /
    /// Slack / other external links). 0 if attachments are empty.
    /// (`linkedGitHubPRCount + linkedSlackMessageCount + other`).
    public let linkedAttachmentCount: Int
    /// Phase Track-1 D1 — issue.description body (markdown). nil if Linear returned null.
    /// On-device only (ADR-010 §6 amendment). Already cap-truncated by provider (BodyCap).
    public let description: String?
    /// Phase Track-1 D1 — true if description was truncated by BodyCap in the provider.
    /// Lets LinearCollector.makeEvent emit `body_truncated` payload key without importing
    /// LeafCorePrivate (circular dependency prevention).
    public let descriptionTruncated: Bool
    /// Phase Track-1 D1 — captured comment bodies for issues touched in this tick.
    /// Already cap-truncated by provider (BodyCap). Empty = no viewer comments in window.
    /// (`commentCountInWindow` retained as fallback count for backward compat.)
    public let comments: [LinearCommentBody]
    /// Phase Track-1 D1 — attachment metadata (name / mime / size_bytes); NEVER content.
    /// Empty array = no attachments on issue.
    public let attachments: [AttachmentMeta]

    public init(
        issueKey: String,
        title: String,
        status: String,
        project: String,
        teamKey: String,
        updatedAtMs: Int64,
        completionSeconds: Int? = nil,
        commentCountInWindow: Int = 0,
        incomingCommentCount: Int = 0,
        linkedGitHubPRCount: Int = 0,
        linkedGitHubTopRepo: String? = nil,
        linkedSlackMessageCount: Int = 0,
        linkedAttachmentCount: Int = 0,
        description: String? = nil,
        descriptionTruncated: Bool = false,
        comments: [LinearCommentBody] = [],
        attachments: [AttachmentMeta] = []
    ) {
        self.issueKey = issueKey
        self.title = title
        self.status = status
        self.project = project
        self.teamKey = teamKey
        self.updatedAtMs = updatedAtMs
        self.completionSeconds = completionSeconds
        self.commentCountInWindow = commentCountInWindow
        self.incomingCommentCount = incomingCommentCount
        self.linkedGitHubPRCount = linkedGitHubPRCount
        self.linkedGitHubTopRepo = linkedGitHubTopRepo
        self.linkedSlackMessageCount = linkedSlackMessageCount
        self.linkedAttachmentCount = linkedAttachmentCount
        self.description = description
        self.descriptionTruncated = descriptionTruncated
        self.comments = comments
        self.attachments = attachments
    }
}

/// Phase 4.6.B — my status transition in Linear (the my-actor filter is applied
/// client-side in the provider, because the `Issue.history` connection in the Linear API
/// does not support a `filter` arg). Public-safe: state names + types + history id.
/// ADR-010: actor display name / state UUIDs / comment bodies do NOT leave the parser.
public struct LinearStateTransitionSnapshot: Sendable, Hashable {
    /// e.g. "LEA-123" — same convention as LinearIssueSnapshot.
    public let issueKey: String
    /// Linear's IssueHistory.id — for client-side dedup on retry ticks.
    /// Internal API id, not PII.
    public let historyId: String
    /// Epoch ms — the moment of the transition (history.createdAt).
    public let transitionAtMs: Int64
    /// nil if the from-state is missing (e.g. issue creation).
    public let fromStateName: String?
    /// nil if the from-state is missing. Linear's WorkflowState.type enum:
    /// triage / backlog / unstarted / started / completed / canceled.
    public let fromStateType: String?
    public let toStateName: String
    public let toStateType: String

    public init(
        issueKey: String,
        historyId: String,
        transitionAtMs: Int64,
        fromStateName: String?,
        fromStateType: String?,
        toStateName: String,
        toStateType: String
    ) {
        self.issueKey = issueKey
        self.historyId = historyId
        self.transitionAtMs = transitionAtMs
        self.fromStateName = fromStateName
        self.fromStateType = fromStateType
        self.toStateName = toStateName
        self.toStateType = toStateType
    }
}

/// Phase 4.7.C — Linear Initiative observation. Membership-style snapshot
/// (NOT state-change). Emitted one-to-one per initiative per tick;
/// `observedAtMs` is fixed as the tick timestamp (NOT initiative.updatedAt) —
/// each tick "observes" the current list of my-related initiatives. Skeleton-
/// style: viewer.initiatives — newer Linear API; graceful degrade on a
/// missing/null field.
/// ADR-010: id + name + status (raw enum string)?; description / goals /
/// content — never (the provider does not even request them).
public struct LinearInitiativeSnapshot: Sendable, Hashable {
    public let initiativeId: String
    /// Self-authored initiative name. Public-safe.
    public let name: String
    /// Linear's status enum raw string; `nil` if the status field is omitted.
    public let status: String?
    /// Tick timestamp (epoch ms) — the moment of observation, NOT initiative.updatedAt.
    public let observedAtMs: Int64

    public init(initiativeId: String, name: String, status: String?, observedAtMs: Int64) {
        self.initiativeId = initiativeId
        self.name = name
        self.status = status
        self.observedAtMs = observedAtMs
    }
}

/// Phase 4.7.C — Linear Document snapshot. Document — first-class top-level
/// type in Linear, similar to wiki page. Skeleton-style: not all workspaces
/// expose feature → graceful degrade on a missing field.
/// ADR-010: id + updatedAt + project{id,name}? + title (parity with issue.title);
/// content / preview / body — never.
public struct LinearDocumentSnapshot: Sendable, Hashable {
    public let documentId: String
    public let updatedAtMs: Int64
    /// `nil` if the document is standalone (not tied to a project).
    public let projectId: String?
    public let projectName: String?
    /// Self-authored document title (e.g. "Q4 Roadmap"). Public-safe per Section 6.
    public let title: String

    public init(documentId: String, updatedAtMs: Int64,
                projectId: String?, projectName: String?, title: String) {
        self.documentId = documentId
        self.updatedAtMs = updatedAtMs
        self.projectId = projectId
        self.projectName = projectName
        self.title = title
    }
}

/// Phase 4.7.C — ProjectUpdate snapshot. ProjectUpdate — first-class top-level
/// type in Linear; piggy-back fragment in the main query via
/// `projectUpdates(filter: { user: { isMe: { eq: true } } })`.
/// ADR-010: body is NOT requested; health enum (onTrack/atRisk/offTrack) +
/// project.id + project.name (self-authored, public-safe).
public struct LinearProjectUpdateSnapshot: Sendable, Hashable {
    public let updateId: String
    public let createdAtMs: Int64
    public let projectId: String
    public let projectName: String
    /// Linear's health enum raw string ("onTrack" / "atRisk" / "offTrack");
    /// `nil` if the field is omitted (project without health tracking).
    public let health: String?

    public init(updateId: String, createdAtMs: Int64,
                projectId: String, projectName: String, health: String?) {
        self.updateId = updateId
        self.createdAtMs = createdAtMs
        self.projectId = projectId
        self.projectName = projectName
        self.health = health
    }
}

/// Phase 4.7.C — estimate transition (story points). Optional from/to:
/// `nil` ↔ unestimated. Linear API stores estimate as Float / Double.
/// Reject equal (`from == to`) and both nil.
public struct LinearEstimateTransitionSnapshot: Sendable, Hashable {
    public let issueKey: String
    public let historyId: String
    public let transitionAtMs: Int64
    public let fromEstimate: Double?
    public let toEstimate: Double?

    public init(issueKey: String, historyId: String, transitionAtMs: Int64,
                fromEstimate: Double?, toEstimate: Double?) {
        self.issueKey = issueKey
        self.historyId = historyId
        self.transitionAtMs = transitionAtMs
        self.fromEstimate = fromEstimate
        self.toEstimate = toEstimate
    }
}

/// Phase 4.7.C — cycle transition snapshot. Optional from/to: `nil` ↔ unscheduled.
/// Captures three transition kinds:
/// - added (from nil → cycle)
/// - moved between cycles (different ids)
/// - removed (cycle → nil)
/// Reject: `from == to` (defensive, degenerate noop) and both nil.
/// ADR-010: cycle.id + cycle.name (self-authored team-level metadata, public-safe);
/// description / goals are NOT requested.
public struct LinearCycleTransitionSnapshot: Sendable, Hashable {
    public let issueKey: String
    public let historyId: String
    public let transitionAtMs: Int64
    public let fromCycleId: String?
    public let fromCycleName: String?
    public let toCycleId: String?
    public let toCycleName: String?

    public init(
        issueKey: String, historyId: String, transitionAtMs: Int64,
        fromCycleId: String?, fromCycleName: String?,
        toCycleId: String?, toCycleName: String?
    ) {
        self.issueKey = issueKey
        self.historyId = historyId
        self.transitionAtMs = transitionAtMs
        self.fromCycleId = fromCycleId
        self.fromCycleName = fromCycleName
        self.toCycleId = toCycleId
        self.toCycleName = toCycleName
    }
}

/// Phase 4.7.C — assignee transition snapshot. Anonymized self/other bucketing
/// — raw third-party assignee IDs are NOT stored (ADR-010 PII concern). The bucket
/// captures the actionable shape (`reassigned_self_to_other` is informative for the
/// user's workload sense, without revealing coworker identity).
public struct LinearAssigneeTransitionSnapshot: Sendable, Hashable {
    public enum Bucket: String, Sendable, Hashable {
        case assignedToSelf = "assigned_to_self"
        case assignedToOther = "assigned_to_other"
        case unassignedFromSelf = "unassigned_from_self"
        case unassignedFromOther = "unassigned_from_other"
        case reassignedSelfToOther = "reassigned_self_to_other"
        case reassignedOtherToSelf = "reassigned_other_to_self"
        case reassignedOtherToOther = "reassigned_other_to_other"
    }
    public let issueKey: String
    public let historyId: String
    public let transitionAtMs: Int64
    public let bucket: Bucket

    public init(issueKey: String, historyId: String, transitionAtMs: Int64,
                bucket: Bucket) {
        self.issueKey = issueKey
        self.historyId = historyId
        self.transitionAtMs = transitionAtMs
        self.bucket = bucket
    }
}

/// Phase 4.7.C — label transition. One history entry with N added + M removed
/// labels expands into N+M snaps (one per label change). Each snap
/// carries a kind discriminator + label.id + label.name. ADR-010: only id + name —
/// label description / color are NOT requested by the provider.
public struct LinearLabelTransitionSnapshot: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case added
        case removed
    }
    public let issueKey: String
    public let historyId: String
    public let transitionAtMs: Int64
    public let kind: Kind
    /// Linear's internal label UUID. Public-safe metadata (not PII).
    public let labelId: String
    /// Self-authored label name (e.g. "bug", "p1") — per Section 6 OK.
    public let labelName: String

    public init(issueKey: String, historyId: String, transitionAtMs: Int64,
                kind: Kind, labelId: String, labelName: String) {
        self.issueKey = issueKey
        self.historyId = historyId
        self.transitionAtMs = transitionAtMs
        self.kind = kind
        self.labelId = labelId
        self.labelName = labelName
    }
}

/// Phase 4.7.C — priority transition (Linear int enum: 1=Urgent .. 4=Low; 0=NoPriority).
/// Mirrors LinearStateTransitionSnapshot: same actor-filter + cursor-guard discipline,
/// emitted one-to-one per qualifying history entry.
/// ADR-010: only raw int values + history id + timestamp; no display labels.
public struct LinearPriorityTransitionSnapshot: Sendable, Hashable {
    public let issueKey: String
    public let historyId: String
    public let transitionAtMs: Int64
    public let fromPriority: Int
    public let toPriority: Int

    public init(issueKey: String, historyId: String, transitionAtMs: Int64,
                fromPriority: Int, toPriority: Int) {
        self.issueKey = issueKey
        self.historyId = historyId
        self.transitionAtMs = transitionAtMs
        self.fromPriority = fromPriority
        self.toPriority = toPriority
    }
}

// MARK: - Phase Track-3 D1 — hot piggy-back snapshot types

/// Phase Track-3 D1 — viewer's comment reaction event (filtered server-side
/// to `user.id == viewer.id` so only own reactions enter the batch).
/// ADR-010: emoji shortcode + IDs only — no third-party identity / message body.
public struct LinearCommentReactionSnapshot: Sendable, Hashable {
    public let id: String
    public let commentId: String
    public let issueId: String
    public let issueIdentifier: String
    public let emoji: String
    public let createdAtMs: Int64

    public init(id: String, commentId: String, issueId: String, issueIdentifier: String, emoji: String, createdAtMs: Int64) {
        self.id = id
        self.commentId = commentId
        self.issueId = issueId
        self.issueIdentifier = issueIdentifier
        self.emoji = emoji
        self.createdAtMs = createdAtMs
    }
}

/// Phase Track-3 D1 — issue relation transition snapshot. `relationKind` is one of
/// {blocks, blocked_by, related, duplicate} (Linear API enum, public substrate).
public struct LinearRelationSnapshot: Sendable, Hashable {
    public let id: String
    public let fromIssueId: String
    public let fromIssueIdentifier: String
    public let toIssueId: String
    public let toIssueIdentifier: String
    public let relationKind: String
    public let transitionedAtMs: Int64

    public init(id: String, fromIssueId: String, fromIssueIdentifier: String,
                toIssueId: String, toIssueIdentifier: String,
                relationKind: String, transitionedAtMs: Int64) {
        self.id = id
        self.fromIssueId = fromIssueId
        self.fromIssueIdentifier = fromIssueIdentifier
        self.toIssueId = toIssueId
        self.toIssueIdentifier = toIssueIdentifier
        self.relationKind = relationKind
        self.transitionedAtMs = transitionedAtMs
    }
}

/// Phase Track-3 D1 — triage queue transition snapshot. `resolutionKind` is
/// `nil` for picked_up flavor; `completed` | `canceled` for resolved flavor.
/// Provider discriminates picked_up vs resolved by reading `toStateType`
/// (Linear's WorkflowState.type enum is public API).
public struct LinearTriageTransitionSnapshot: Sendable, Hashable {
    public let issueId: String
    public let issueIdentifier: String
    public let teamId: String
    public let toStateName: String
    public let toStateType: String
    public let transitionedAtMs: Int64
    public let resolutionKind: String?

    public init(issueId: String, issueIdentifier: String, teamId: String,
                toStateName: String, toStateType: String,
                transitionedAtMs: Int64, resolutionKind: String?) {
        self.issueId = issueId
        self.issueIdentifier = issueIdentifier
        self.teamId = teamId
        self.toStateName = toStateName
        self.toStateType = toStateType
        self.transitionedAtMs = transitionedAtMs
        self.resolutionKind = resolutionKind
    }
}

// MARK: - Phase Track-3 D1 — warm-tier snapshot types

/// Phase Track-3 D1 — single Linear notification entry.
/// `readAtMs` / `archivedAtMs` are non-nil when the corresponding transition
/// has occurred — collector emits `_read` / `_archived` flavors when those
/// timestamps are newer than the warm cursor.
public struct LinearNotificationSnapshot: Sendable, Hashable {
    public let id: String
    public let kind: String
    public let issueId: String?
    public let issueIdentifier: String?
    public let title: String
    public let createdAtMs: Int64
    public let readAtMs: Int64?
    public let archivedAtMs: Int64?

    public init(id: String, kind: String, issueId: String?, issueIdentifier: String?,
                title: String, createdAtMs: Int64, readAtMs: Int64?, archivedAtMs: Int64?) {
        self.id = id
        self.kind = kind
        self.issueId = issueId
        self.issueIdentifier = issueIdentifier
        self.title = title
        self.createdAtMs = createdAtMs
        self.readAtMs = readAtMs
        self.archivedAtMs = archivedAtMs
    }
}

/// Phase Track-3 D1 — viewer's currently-subscribed issue identity for diff.
public struct LinearSubscribedIssueSnapshot: Sendable, Hashable {
    public let id: String
    public let identifier: String
    public init(id: String, identifier: String) {
        self.id = id
        self.identifier = identifier
    }
}

/// Phase Track-3 D1 — cycle lifecycle snapshot. Provider buckets started vs
/// completed by timestamp filter; collector emits one event per snapshot.
public struct LinearCycleLifecycleSnapshot: Sendable, Hashable {
    public let id: String
    public let number: Int
    public let teamId: String
    public let name: String?
    public let startsAtMs: Int64
    public let endsAtMs: Int64
    public let completedAtMs: Int64?
    public let progress: Double?
    public let issuesCompletedCount: Int?

    public init(id: String, number: Int, teamId: String, name: String?,
                startsAtMs: Int64, endsAtMs: Int64, completedAtMs: Int64?,
                progress: Double?, issuesCompletedCount: Int?) {
        self.id = id
        self.number = number
        self.teamId = teamId
        self.name = name
        self.startsAtMs = startsAtMs
        self.endsAtMs = endsAtMs
        self.completedAtMs = completedAtMs
        self.progress = progress
        self.issuesCompletedCount = issuesCompletedCount
    }
}

/// Phase Track-3 D1 — bundled output of a single warm-tier GraphQL call.
/// Provider returns pre-bucketed cycle started/completed; collector applies
/// subscribed-issues diff against the prior snapshot.
public struct LinearWarmBatch: Sendable, Hashable {
    public let notifications: [LinearNotificationSnapshot]
    public let notificationCursorMs: Int64?
    public let cyclesStarted: [LinearCycleLifecycleSnapshot]
    public let cyclesCompleted: [LinearCycleLifecycleSnapshot]
    public let cyclesCursorMs: Int64?
    public let subscribedIssueIds: [LinearSubscribedIssueSnapshot]

    public init(
        notifications: [LinearNotificationSnapshot] = [],
        notificationCursorMs: Int64? = nil,
        cyclesStarted: [LinearCycleLifecycleSnapshot] = [],
        cyclesCompleted: [LinearCycleLifecycleSnapshot] = [],
        cyclesCursorMs: Int64? = nil,
        subscribedIssueIds: [LinearSubscribedIssueSnapshot] = []
    ) {
        self.notifications = notifications
        self.notificationCursorMs = notificationCursorMs
        self.cyclesStarted = cyclesStarted
        self.cyclesCompleted = cyclesCompleted
        self.cyclesCursorMs = cyclesCursorMs
        self.subscribedIssueIds = subscribedIssueIds
    }

    public static let empty = LinearWarmBatch()
}

// MARK: - Phase Track-3 D1 — cold-tier snapshot types

/// Phase Track-3 D1 — per-project entry inside a roadmap.
public struct LinearRoadmapProjectSnapshot: Sendable, Hashable {
    public let projectId: String
    public let projectName: String
    public let stateEnum: String

    public init(projectId: String, projectName: String, stateEnum: String) {
        self.projectId = projectId
        self.projectName = projectName
        self.stateEnum = stateEnum
    }
}

/// Phase Track-3 D1 — roadmap snapshot. Collector emits one
/// `linear_roadmap_state_observed` event per (roadmap × project) pair every
/// cold tick (heartbeat-per-tick — mirrors `linear_initiative_observed`).
public struct LinearRoadmapSnapshot: Sendable, Hashable {
    public let id: String
    public let name: String?
    public let projects: [LinearRoadmapProjectSnapshot]

    public init(id: String, name: String?, projects: [LinearRoadmapProjectSnapshot]) {
        self.id = id
        self.name = name
        self.projects = projects
    }
}

/// Phase Track-3 D1 — custom view identity for diff.
public struct LinearCustomViewSnapshot: Sendable, Hashable {
    public let id: String
    public let name: String
    public let teamId: String?
    public let updatedAtMs: Int64

    public init(id: String, name: String, teamId: String?, updatedAtMs: Int64) {
        self.id = id
        self.name = name
        self.teamId = teamId
        self.updatedAtMs = updatedAtMs
    }
}

/// Phase Track-3 D1 — viewer's project membership identity for diff.
public struct LinearProjectMembershipSnapshot: Sendable, Hashable {
    public let projectId: String
    public let projectName: String

    public init(projectId: String, projectName: String) {
        self.projectId = projectId
        self.projectName = projectName
    }
}

/// Phase Track-3 D1 — bundled output of cold-tier GraphQL call.
public struct LinearColdBatch: Sendable, Hashable {
    public let roadmaps: [LinearRoadmapSnapshot]
    public let customViews: [LinearCustomViewSnapshot]
    public let projectMemberships: [LinearProjectMembershipSnapshot]

    public init(
        roadmaps: [LinearRoadmapSnapshot] = [],
        customViews: [LinearCustomViewSnapshot] = [],
        projectMemberships: [LinearProjectMembershipSnapshot] = []
    ) {
        self.roadmaps = roadmaps
        self.customViews = customViews
        self.projectMemberships = projectMemberships
    }

    public static let empty = LinearColdBatch()
}

/// Stub for CI / dev-without-moat builds. Never makes an HTTP call,
/// returns `.empty` — the LinearCollector tick runs as a no-op.
public struct StubLinearGraphQLProvider: LinearGraphQLProvider, LinearGraphQLProviding {
    public init() {}
    public func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch {
        .empty
    }
    public func fetchWarmState(accessToken: String, cursors: LinearWarmCursors) async throws -> LinearWarmBatch {
        .empty
    }
    public func fetchColdState(accessToken: String) async throws -> LinearColdBatch {
        .empty
    }
    /// Track 5 / S6 T9 — empty user list keeps `LinearUsersResolver.resolve`
    /// returning nil for stub builds (no moat / CI environments).
    public func fetchAccessibleUsers() async throws -> [LinearUsersResolver.ResolvedUser] {
        []
    }
}

// MARK: - Track 5 / S6 T9 — LinearGraphQLProviding (assignee resolution surface)

/// Phase Track-5 S6 T9 — narrow Sendable surface used by `LinearUsersResolver`
/// for resolving Leaf member → Linear user UUID.
///
/// Separate protocol from `LinearGraphQLProvider` because:
///  - resolver doesn't need access tokens passed in — caller (composition root)
///    wires a concrete provider that already knows how to get its token
///    (via `LinearTokenRefresher` + `IntegrationRecord`);
///  - keeps test mocks tiny — only one method to stub;
///  - decouples resolver from collector-tier provider evolution.
///
/// Production impl lives in LeafCorePrivate (`ProdLinearGraphQLProvider`
/// extension); it executes:
///   `query LeafAccessibleUsers { users(first: 250) { nodes { id name displayName } } }`
/// and maps nodes to `LinearUsersResolver.ResolvedUser`.
public protocol LinearGraphQLProviding: Sendable {
    /// Returns viewer's accessible Linear users (~50 typically; Linear API
    /// pages at 250). One HTTP call; caller (resolver) caches with 5min TTL.
    func fetchAccessibleUsers() async throws -> [LinearUsersResolver.ResolvedUser]
}
