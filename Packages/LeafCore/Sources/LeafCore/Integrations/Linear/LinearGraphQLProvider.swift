//
//  LinearGraphQLProvider.swift
//  LeafCore
//
//  Phase 4.2 — protocol для GraphQL polling Linear (issues filter updatedAt).
//  Prod implementation (paginated + retry + complexity budget) живёт в
//  LeafCorePrivate (moat). Public Stub возвращает empty result —
//  CI builds компилируются, runtime no-op.
//

import Foundation

public protocol LinearGraphQLProvider: Sendable {
    /// `since` — epoch ms cursor (newest processed `updatedAt` от прошлого tick'а).
    /// `nil` = bootstrap: provider решает window сам (default 7d backwards).
    /// Возвращает batch + cursor; throws на network/parsing failures.
    func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch
}

/// Результат одного GraphQL fetch'а. `cursorMs` — `max(updatedAt)` across `issues`,
/// или `nil` если batch пуст (cursor не двигается, retry на следующем tick).
/// Phase 4.6.B — additive `transitions` поле: my status transitions из nested
/// IssueHistory fragment, после client-side filter (Linear API не поддерживает
/// `actor.isMe` filter на history connection).
/// Phase 4.7.B — additive `workload` field: viewer's currently-`started` assigned
/// issues snapshot. Single page (≤50 issues per user типично), single HTTP call —
/// piggy-back на existing `fetchIssues` query через `viewer.assignedIssues` root field.
/// Phase 4.7.B (B-7) — additive `cycles` field: viewer's teams current active cycle
/// progress. Up to 5 teams (cap per design budget), single HTTP call — piggy-back
/// на existing `fetchIssues` query через `viewer.teams.activeCycle` block.
public struct LinearIssueBatch: Sendable, Hashable {
    public let issues: [LinearIssueSnapshot]
    public let cursorMs: Int64?
    public let transitions: [LinearStateTransitionSnapshot]
    public let workload: LinearAssignedWorkloadSnapshot
    public let cycles: LinearCycleSnapshot
    /// Phase 4.7.C — additive transition flavors (priority/labels/assignee/cycle/estimate).
    /// Все piggy-back на той же `Issue.history` connection — никаких extra HTTP calls.
    /// Каждый array — independent: один history entry может породить 0+ snap'ов разных
    /// flavors (priority change + label add + assignee bucket в одной mutation).
    public let priorityTransitions: [LinearPriorityTransitionSnapshot]
    public let labelTransitions: [LinearLabelTransitionSnapshot]
    public let assigneeTransitions: [LinearAssigneeTransitionSnapshot]
    public let cycleTransitions: [LinearCycleTransitionSnapshot]
    public let estimateTransitions: [LinearEstimateTransitionSnapshot]
    /// Phase 4.7.C — ProjectUpdate authored snaps (separate top-level Linear type,
    /// piggy-back fragment в той же query). Empty если provider degrade'нулся
    /// или у юзера нет updates в окне.
    public let projectUpdates: [LinearProjectUpdateSnapshot]
    /// Phase 4.7.C — Linear Document snaps (skeleton). Empty при отсутствии
    /// feature support или нулевой activity юзера.
    public let documents: [LinearDocumentSnapshot]
    /// Phase 4.7.C — Initiatives membership snapshot (skeleton). Empty при
    /// отсутствии feature support / на legacy plans.
    public let initiatives: [LinearInitiativeSnapshot]

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
        initiatives: [LinearInitiativeSnapshot] = []
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
    }

    public static let empty = LinearIssueBatch(
        issues: [], cursorMs: nil, transitions: [], workload: .empty, cycles: .empty,
        priorityTransitions: [], labelTransitions: [], assigneeTransitions: [],
        cycleTransitions: [], estimateTransitions: [], projectUpdates: [],
        documents: [], initiatives: []
    )
}

/// Phase 4.7.B — snapshot моих assigned `started` issues (current workload pulse).
/// Substrate под Phase 5 broadcast (presence_state.linear) и MCP `get_workload_pulse`.
/// Источник: `viewer.assignedIssues(filter: { state: { type: { in: [started] } } })`,
/// single page first:50.
///
/// ADR-010 — title / description / body НЕ запрашиваются. Public-safe metadata only:
/// counts, priority enum (Linear's int), identifier (self-authored label), updatedAt.
public struct LinearAssignedWorkloadSnapshot: Sendable, Hashable {
    /// Сколько issues с `state.type == "started"` assigned на меня прямо сейчас.
    /// 0 если у меня ничего in-flight.
    public let startedCount: Int
    /// Linear priority enum: 1=urgent, 2=high, 3=normal, 4=low. `nil` если:
    /// (а) startedCount == 0, (б) все issues с priority == 0 ("no priority" в Linear).
    /// Минимум по issues — самый срочный приоритет в текущей нагрузке.
    public let topPriority: Int?
    /// Identifier (e.g. "LEA-123") issue с самым свежим `updatedAt` в started bucket.
    /// `nil` если startedCount == 0.
    public let lastTouchedIdentifier: String?
    /// Epoch ms того самого most-recent `updatedAt`.
    /// `nil` если startedCount == 0.
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
/// Один из ≤5 teams юзера (`viewer.teams(first: 5).nodes[].activeCycle`).
/// Source: `viewer.teams.activeCycle.{scopeHistory, completedScopeHistory, progress}`.
///
/// ADR-010 — cycle.description / cycle goals / любой long-form text НЕ запрашиваются
/// и НЕ парсятся. Только public-safe metadata: cycle id (internal), self-authored
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
    /// `(endsAtMs - nowMs) / 86_400_000` floored, clamped к 0 если cycle уже завершён.
    public let daysRemaining: Int
    /// Total scope (`scopeHistory.last` rounded к Int). 0 если scope history пуст.
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

/// Phase 4.7.B (B-7) — aggregate snapshot всех teams юзера с активным cycle'ом.
/// Teams без `activeCycle` (Linear возвращает null) skip'аются — `teams` array
/// содержит только teams где cycle in-flight. Empty `teams` = nothing in-flight,
/// downstream LinearCollector ничего не emit'ит (никаких cycle events).
public struct LinearCycleSnapshot: Sendable, Hashable {
    /// Per-team снимок active cycle. Up to 5 entries (provider cap).
    public let teams: [LinearTeamCycleSnapshot]
    /// Snapshot capture timestamp (epoch ms). 0 если snapshot пуст (`.empty`).
    public let observedAtMs: Int64

    public init(teams: [LinearTeamCycleSnapshot], observedAtMs: Int64) {
        self.teams = teams
        self.observedAtMs = observedAtMs
    }

    public static let empty = LinearCycleSnapshot(teams: [], observedAtMs: 0)
}

/// Один issue в batch'е — public-safe metadata (whitepaper Section 6 Action signal).
/// Bodies / comment text НЕ хранятся (ADR-010 won't-list).
public struct LinearIssueSnapshot: Sendable, Hashable {
    /// e.g. "LEA-123" — self-authored label, public-safe.
    public let issueKey: String
    /// Self-authored, OK по Section 6.
    public let title: String
    /// Workflow state name, e.g. "In Progress".
    public let status: String
    /// Project name; "" если issue не в project.
    public let project: String
    /// Team key, e.g. "LEA".
    public let teamKey: String
    /// Epoch ms — становится cursor для следующего polling tick'а.
    public let updatedAtMs: Int64
    /// Phase 4.6.A.2 — `completedAt - startedAt` в секундах для issues, completed
    /// в polling window (provider dedup'ит чтобы не пересчитывать sample при
    /// post-completion активности). `nil` если: (а) issue не completed,
    /// (б) startedAt отсутствует, (в) completedAt раньше polling cursor'а.
    /// Clock skew clamped к 0.
    public let completionSeconds: Int?
    /// Phase 4.7.A — count моих comment'ов в этом issue, приходящихся на tick window
    /// (`createdAt > effectiveSince`, filter actor по `user.id == viewer.id`,
    /// applied client-side в parser'е). 0 если не было моих comments.
    /// ADR-010: bodies НЕ запрашиваются — только id + createdAt + user.id для filter.
    public let commentCountInWindow: Int
    /// Phase 4.7.B (B-8) — counts of GitHub PR attachments на этом issue, derived
    /// из `Issue.attachments(first: 10)` block'а парсером URL'ов. 0 если ни один
    /// attachment не matched GitHub PR pattern (или вообще не attached).
    public let linkedGitHubPRCount: Int
    /// Phase 4.7.B (B-8) — most-frequent `<owner>/<repo>` среди GitHub PR attachments
    /// на этом issue. `nil` если linkedGitHubPRCount==0. Tie-break — lex-smallest
    /// repo при равных counts (deterministic across test fixtures + production).
    public let linkedGitHubTopRepo: String?
    /// Phase 4.7.B (B-8) — counts Slack permalink attachments (matched
    /// `https://<workspace>.slack.com/archives/<channel>/p<ts>` pattern).
    /// 0 если ни один attachment не matched. ADR-010: только URL structure парсится,
    /// message text / preview не запрашиваются.
    public let linkedSlackMessageCount: Int
    /// Phase 4.7.B (B-8) — total count attachments на issue (всех типов: GitHub /
    /// Slack / другие external links). 0 если attachments пусты.
    /// (`linkedGitHubPRCount + linkedSlackMessageCount + other`).
    public let linkedAttachmentCount: Int

    public init(
        issueKey: String,
        title: String,
        status: String,
        project: String,
        teamKey: String,
        updatedAtMs: Int64,
        completionSeconds: Int? = nil,
        commentCountInWindow: Int = 0,
        linkedGitHubPRCount: Int = 0,
        linkedGitHubTopRepo: String? = nil,
        linkedSlackMessageCount: Int = 0,
        linkedAttachmentCount: Int = 0
    ) {
        self.issueKey = issueKey
        self.title = title
        self.status = status
        self.project = project
        self.teamKey = teamKey
        self.updatedAtMs = updatedAtMs
        self.completionSeconds = completionSeconds
        self.commentCountInWindow = commentCountInWindow
        self.linkedGitHubPRCount = linkedGitHubPRCount
        self.linkedGitHubTopRepo = linkedGitHubTopRepo
        self.linkedSlackMessageCount = linkedSlackMessageCount
        self.linkedAttachmentCount = linkedAttachmentCount
    }
}

/// Phase 4.6.B — мой status transition в Linear (my-actor filter применён
/// client-side в провайдере, потому что `Issue.history` connection в Linear API
/// не поддерживает `filter` arg). Public-safe: state names + types + history id.
/// ADR-010: actor display name / state UUIDs / comment bodies НЕ покидают парсер.
public struct LinearStateTransitionSnapshot: Sendable, Hashable {
    /// e.g. "LEA-123" — same convention что и LinearIssueSnapshot.
    public let issueKey: String
    /// Linear's IssueHistory.id — для client-side dedup на retry tick'ах.
    /// Internal API id, не PII.
    public let historyId: String
    /// Epoch ms — момент transition (history.createdAt).
    public let transitionAtMs: Int64
    /// nil если from-state отсутствует (e.g. issue creation).
    public let fromStateName: String?
    /// nil если from-state отсутствует. Linear's WorkflowState.type enum:
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
/// (NOT state-change). Emit'ится один-к-одному per initiative per tick;
/// `observedAtMs` фиксируется как tick timestamp (НЕ initiative.updatedAt) —
/// каждый tick "наблюдает" текущий список my-related initiatives. Skeleton-
/// style: viewer.initiatives — newer Linear API; graceful degrade на
/// missing/null field.
/// ADR-010: id + name + status (raw enum string)?; description / goals /
/// content — никогда (provider их и не запрашивает).
public struct LinearInitiativeSnapshot: Sendable, Hashable {
    public let initiativeId: String
    /// Self-authored initiative name. Public-safe.
    public let name: String
    /// Linear's status enum raw string; `nil` если status field omitted.
    public let status: String?
    /// Tick timestamp (epoch ms) — момент наблюдения, НЕ initiative.updatedAt.
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
/// expose feature → graceful degrade на missing field.
/// ADR-010: id + updatedAt + project{id,name}? + title (parity с issue.title);
/// content / preview / body — никогда.
public struct LinearDocumentSnapshot: Sendable, Hashable {
    public let documentId: String
    public let updatedAtMs: Int64
    /// `nil` если document standalone (не привязан к project).
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
/// type в Linear; piggy-back fragment в основной query через
/// `projectUpdates(filter: { user: { isMe: { eq: true } } })`.
/// ADR-010: body НЕ запрашивается; health enum (onTrack/atRisk/offTrack) +
/// project.id + project.name (self-authored, public-safe).
public struct LinearProjectUpdateSnapshot: Sendable, Hashable {
    public let updateId: String
    public let createdAtMs: Int64
    public let projectId: String
    public let projectName: String
    /// Linear's health enum raw string ("onTrack" / "atRisk" / "offTrack");
    /// `nil` если field omitted (project без health tracking).
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
/// `nil` ↔ unestimated. Linear API stores estimate как Float / Double.
/// Reject equal (`from == to`) и обе nil.
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
/// Reject: `from == to` (defensive, degenerate noop) и обе nil.
/// ADR-010: cycle.id + cycle.name (self-authored team-level metadata, public-safe);
/// description / goals НЕ запрашиваются.
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
/// — raw third-party assignee IDs НЕ хранятся (ADR-010 PII concern). Bucket
/// захватывает actionable shape (`reassigned_self_to_other` информативно для
/// user'ского workload sense, без раскрытия coworker identity).
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

/// Phase 4.7.C — label transition. Один history entry с N added + M removed
/// labels раскладывается в N+M snap'ов (один per label change). Каждый snap
/// несёт kind discriminator + label.id + label.name. ADR-010: только id + name —
/// label description / color НЕ запрашиваются провайдером.
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
/// emit'ится один-к-одному per qualifying history entry.
/// ADR-010: только raw int values + history id + timestamp; никаких display labels.
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

/// Stub для CI / dev-без-moat сборок. Никогда не делает HTTP call,
/// возвращает `.empty` — LinearCollector tick проходит no-op.
public struct StubLinearGraphQLProvider: LinearGraphQLProvider {
    public init() {}
    public func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch {
        .empty
    }
}
