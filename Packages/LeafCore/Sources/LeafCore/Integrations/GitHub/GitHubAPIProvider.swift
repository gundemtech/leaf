//
//  GitHubAPIProvider.swift
//  LeafCore
//
//  Phase 4.3 — protocol для REST polling GitHub events feed.
//  Prod implementation (`GET /users/<login>/events?per_page=100`, parsing
//  PushEvent/PullRequestEvent/IssuesEvent/PullRequestReviewEvent payloads,
//  ADR-010 enforcement) живёт в LeafCorePrivate (moat). Public Stub возвращает
//  empty result — CI builds компилируются, runtime no-op.
//

import Foundation

public protocol GitHubAPIProvider: Sendable {
    /// `since` — epoch ms cursor (newest processed `created_at` от прошлого tick'а).
    /// `nil` = bootstrap, provider решает window сам (default: первая страница events feed,
    /// REST events ограничен ~90 днями).
    /// Provider фильтрует client-side: `event.createdAtMs > since`. Возвращает batch + cursor;
    /// throws на network/parsing failures. `login` — viewer login из `GET /user`,
    /// used для path `/users/<login>/events`.
    func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch
}

/// Результат одного REST fetch'а. `cursorMs` — `max(createdAt)` across `events`
/// (REST events feed DESC by `created_at` → `events.first?.createdAtMs`),
/// или `nil` если batch пуст (cursor не двигается, retry next tick).
/// Mirroring `LinearIssueBatch` — schema-aligned timestamp cursor вместо eventID-as-cursor
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

/// Один event в batch'е — public-safe metadata (whitepaper Section 6 Action signal).
/// Bodies / comment text / file diffs НЕ хранятся (ADR-010 won't-list); commit message —
/// только первая строка (subject), всё после `\n` отбрасывается на уровне provider'а.
public struct GitHubEventSnapshot: Sendable, Hashable {
    /// REST events `id` — used for parser-side dedup внутри одного fetch'а
    /// (cursor-by-timestamp imperfect для events с identical `created_at`).
    public let eventID: String
    /// Канонический kind после маппинга raw GitHub `type` + `payload.action`.
    /// MVP supported: "commit_pushed" | "pr_opened" | "pr_merged" | "pr_closed"
    /// | "issue_opened" | "issue_closed" | "review_submitted".
    public let eventKind: String
    /// "owner/name" — self-authored repo identifier, public-safe.
    public let repoFullName: String
    /// Commit subject (только первая строка) для commit_pushed; PR title; issue title.
    public let title: String
    /// PR/issue number; `nil` для commit_pushed / review_submitted без issue context.
    public let number: Int?
    /// Commit SHA (short or full) для PushEvent; `nil` для не-push.
    public let sha: String?
    /// Branch ref (e.g. "main") для PushEvent — извлекается из `refs/heads/<x>`.
    public let branch: String?
    /// Epoch ms — становится cursor для следующего polling tick'а (max `createdAtMs`
    /// идёт в `GitHubEventBatch.cursorMs` → `collector_offsets.last_modified_ms`).
    public let createdAtMs: Int64

    public init(
        eventID: String,
        eventKind: String,
        repoFullName: String,
        title: String,
        number: Int?,
        sha: String?,
        branch: String?,
        createdAtMs: Int64
    ) {
        self.eventID = eventID
        self.eventKind = eventKind
        self.repoFullName = repoFullName
        self.title = title
        self.number = number
        self.sha = sha
        self.branch = branch
        self.createdAtMs = createdAtMs
    }
}

/// Stub для CI / dev-без-moat сборок. Никогда не делает HTTP call, возвращает
/// `.empty` — GitHubCollector tick проходит no-op.
public struct StubGitHubAPIProvider: GitHubAPIProvider {
    public init() {}
    public func fetchEvents(accessToken: String, login: String, since: Int64?) async throws -> GitHubEventBatch {
        .empty
    }
}
