import Foundation

/// Track-10 T8 — single source of truth for GitHub `event_kind` discriminators
/// consumed by post-recentActivityFeed callers (StandupComposer.countReviewedPRs).
/// Mirrors the `LinearActivityKinds` pattern; values verified by grep against
/// `ProdInsights+RecentActivityFeed.swift` allow-list and emitter sites.
///
/// `prReviewAuthoredKind` is "I reviewed someone else's PR" (distinct from
/// `gh_pr_review_requested` which is "review requested OF me").
public enum GitHubActivityKinds {
    public static let prReviewAuthoredKind = "gh_pr_review_authored"
}
