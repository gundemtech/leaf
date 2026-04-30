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
public struct LinearIssueBatch: Sendable, Hashable {
    public let issues: [LinearIssueSnapshot]
    public let cursorMs: Int64?

    public init(issues: [LinearIssueSnapshot], cursorMs: Int64?) {
        self.issues = issues
        self.cursorMs = cursorMs
    }

    public static let empty = LinearIssueBatch(issues: [], cursorMs: nil)
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

    public init(
        issueKey: String,
        title: String,
        status: String,
        project: String,
        teamKey: String,
        updatedAtMs: Int64,
        completionSeconds: Int? = nil
    ) {
        self.issueKey = issueKey
        self.title = title
        self.status = status
        self.project = project
        self.teamKey = teamKey
        self.updatedAtMs = updatedAtMs
        self.completionSeconds = completionSeconds
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
