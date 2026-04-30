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
    /// Phase 4.6.A.1 — distribution of `closed_at - created_at` (seconds) over
    /// `pr_merged` events в окне. `nil` → нет samples (PRs не закрывали или
    /// timestamps отсутствовали).
    public let prCycleStats: LatencyStats?
    /// Phase 4.6.A.1 — distribution of `review.submitted_at - pull_request.created_at`
    /// (seconds) over `review_submitted` events. Семантика: "сколько чужой PR
    /// ждал моего review". `nil` → нет samples.
    public let reviewDelayStats: LatencyStats?
    /// Phase 4.6.C.1 — reserved под per-provider WoW в 4.7+. Сейчас всегда nil.
    public let wowDeltaPct: Double?

    public init(
        eventsCount: Int,
        byRepo: [RepoCountEntry],
        byEventKind: [EventKindCountEntry],
        prCycleStats: LatencyStats? = nil,
        reviewDelayStats: LatencyStats? = nil,
        wowDeltaPct: Double? = nil
    ) {
        self.eventsCount = eventsCount
        self.byRepo = byRepo
        self.byEventKind = byEventKind
        self.prCycleStats = prCycleStats
        self.reviewDelayStats = reviewDelayStats
        self.wowDeltaPct = wowDeltaPct
    }

    public static let empty = GitHubActivityBreakdown(
        eventsCount: 0,
        byRepo: [],
        byEventKind: [],
        prCycleStats: nil,
        reviewDelayStats: nil,
        wowDeltaPct: nil
    )
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
