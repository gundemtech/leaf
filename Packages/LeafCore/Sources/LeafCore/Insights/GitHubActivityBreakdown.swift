import Foundation

/// Phase 4.3 — GitHub events activity для DerivedInsights.githubActivity(period:).
/// Метаданные only (repo, event_kind, title) — bodies/comments/diffs not stored
/// (ADR-010 won't-list, enforced на уровне ProdGitHubAPIProvider parser'а).
public struct GitHubActivityBreakdown: Sendable, Hashable {
    /// Total events с `signal_type='action'` AND `payload.source='github'` в окне.
    public let eventsCount: Int
    /// Top-5 repo bucket'ов по count, descending. Пустая проекция → пустой массив.
    public let byRepo: [RepoCountEntry]
    /// Top-5 event_kind bucket'ов по count, descending.
    public let byEventKind: [EventKindCountEntry]

    public init(eventsCount: Int, byRepo: [RepoCountEntry], byEventKind: [EventKindCountEntry]) {
        self.eventsCount = eventsCount
        self.byRepo = byRepo
        self.byEventKind = byEventKind
    }

    public static let empty = GitHubActivityBreakdown(eventsCount: 0, byRepo: [], byEventKind: [])
}

public struct RepoCountEntry: Sendable, Hashable, Codable {
    public let repo: String
    public let count: Int
    public init(repo: String, count: Int) {
        self.repo = repo
        self.count = count
    }
}

public struct EventKindCountEntry: Sendable, Hashable, Codable {
    public let eventKind: String
    public let count: Int
    public init(eventKind: String, count: Int) {
        self.eventKind = eventKind
        self.count = count
    }
}
