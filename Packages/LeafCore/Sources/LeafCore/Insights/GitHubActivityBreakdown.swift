import Foundation

/// Phase 4.3 — GitHub events activity for DerivedInsights.githubActivity(period:).
/// Metadata only (repo, event_kind, title) — bodies/comments/diffs not stored
/// (ADR-010 won't-list, enforced in the ProdGitHubAPIProvider parser).
public struct GitHubActivityBreakdown: Sendable, Hashable {
    /// Total events with `signal_type='action'` AND `payload.source='github'` in the window.
    public let eventsCount: Int
    /// Top-5 repo buckets by count, descending. Empty projection → empty array.
    public let byRepo: [RepoCountEntry]
    /// Top-5 event_kind buckets by count, descending.
    public let byEventKind: [EventKindCountEntry]
    /// Phase 4.6.A.1 — distribution of `closed_at - created_at` (seconds) over
    /// `gh_pr_merged` events in the window. `nil` → no samples (no PRs closed, or
    /// timestamps were missing).
    public let prCycleStats: LatencyStats?
    /// Phase 4.6.A.1 — distribution of `review.submitted_at - pull_request.created_at`
    /// (seconds) over `gh_pr_review_submitted` events. Semantics: "how long someone
    /// else's PR waited for my review". `nil` → no samples.
    public let reviewDelayStats: LatencyStats?
    /// Phase 4.6.C.1 — reserved for per-provider WoW in 4.7+. Always nil for now.
    public let wowDeltaPct: Double?
    /// Phase 4.6.C.3 — consecutive days with ≥1 GitHub PushEvent
    /// (event_kind='gh_commit_pushed'), ending today/yesterday. 60-day lookback,
    /// independent of `period` parameter. `nil` ↔ streak=0.
    public let commitStreak: Int?

    public init(
        eventsCount: Int,
        byRepo: [RepoCountEntry],
        byEventKind: [EventKindCountEntry],
        prCycleStats: LatencyStats? = nil,
        reviewDelayStats: LatencyStats? = nil,
        wowDeltaPct: Double? = nil,
        commitStreak: Int? = nil
    ) {
        self.eventsCount = eventsCount
        self.byRepo = byRepo
        self.byEventKind = byEventKind
        self.prCycleStats = prCycleStats
        self.reviewDelayStats = reviewDelayStats
        self.wowDeltaPct = wowDeltaPct
        self.commitStreak = commitStreak
    }

    public static let empty = GitHubActivityBreakdown(
        eventsCount: 0,
        byRepo: [],
        byEventKind: [],
        prCycleStats: nil,
        reviewDelayStats: nil,
        wowDeltaPct: nil,
        commitStreak: nil
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
