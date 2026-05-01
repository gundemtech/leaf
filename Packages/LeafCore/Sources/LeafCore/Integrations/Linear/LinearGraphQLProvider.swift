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
public struct LinearIssueBatch: Sendable, Hashable {
    public let issues: [LinearIssueSnapshot]
    public let cursorMs: Int64?
    public let transitions: [LinearStateTransitionSnapshot]

    public init(
        issues: [LinearIssueSnapshot],
        cursorMs: Int64?,
        transitions: [LinearStateTransitionSnapshot] = []
    ) {
        self.issues = issues
        self.cursorMs = cursorMs
        self.transitions = transitions
    }

    public static let empty = LinearIssueBatch(issues: [], cursorMs: nil, transitions: [])
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

    public init(
        issueKey: String,
        title: String,
        status: String,
        project: String,
        teamKey: String,
        updatedAtMs: Int64,
        completionSeconds: Int? = nil,
        commentCountInWindow: Int = 0
    ) {
        self.issueKey = issueKey
        self.title = title
        self.status = status
        self.project = project
        self.teamKey = teamKey
        self.updatedAtMs = updatedAtMs
        self.completionSeconds = completionSeconds
        self.commentCountInWindow = commentCountInWindow
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

/// Stub для CI / dev-без-moat сборок. Никогда не делает HTTP call,
/// возвращает `.empty` — LinearCollector tick проходит no-op.
public struct StubLinearGraphQLProvider: LinearGraphQLProvider {
    public init() {}
    public func fetchIssues(accessToken: String, since: Int64?) async throws -> LinearIssueBatch {
        .empty
    }
}
