//
//  ReviewActivityResult.swift
//  Track 7 P4 — typed wrapper над ReviewActivityInsights.reviewActivity()
//  dict ([String: Any]). Static decode returns nil для malformed dicts —
//  GitHubDetailViewModel рендерит graceful "Review activity unavailable"
//  placeholder когда decode == nil.
//

import Foundation

public struct ReviewActivityResult: Equatable, Sendable, Hashable {
    public let periodLabel: String
    public let reviewsSubmittedCount: Int
    public let reviewCommentsCount: Int
    public let reviewThreadResolvedCount: Int
    public let byRepo: [RepoEntry]
    public let linkedPRs: [LinkedPREntry]

    public struct RepoEntry: Equatable, Sendable, Hashable {
        public let repo: String
        public let reviews: Int
        public let comments: Int
        public let threads: Int

        public init(repo: String, reviews: Int, comments: Int, threads: Int) {
            self.repo = repo
            self.reviews = reviews
            self.comments = comments
            self.threads = threads
        }
    }

    public struct LinkedPREntry: Equatable, Sendable, Hashable {
        public let repo: String
        public let prNumber: Int
        public let linkedLinearID: String?

        public init(repo: String, prNumber: Int, linkedLinearID: String?) {
            self.repo = repo
            self.prNumber = prNumber
            self.linkedLinearID = linkedLinearID
        }
    }

    public init(
        periodLabel: String,
        reviewsSubmittedCount: Int,
        reviewCommentsCount: Int,
        reviewThreadResolvedCount: Int,
        byRepo: [RepoEntry],
        linkedPRs: [LinkedPREntry]
    ) {
        self.periodLabel = periodLabel
        self.reviewsSubmittedCount = reviewsSubmittedCount
        self.reviewCommentsCount = reviewCommentsCount
        self.reviewThreadResolvedCount = reviewThreadResolvedCount
        self.byRepo = byRepo
        self.linkedPRs = linkedPRs
    }

    /// Decode raw dict from `ReviewActivityInsights.reviewActivity(database:period:)`.
    /// Returns nil если required keys missing или wrong types. Malformed entries
    /// в byRepo / linkedPRs гасятся silently (skip), не приводят к nil overall.
    public static func decode(_ dict: [String: Any]) -> ReviewActivityResult? {
        guard let period = dict["period"] as? String else { return nil }
        let submitted = intOrZero(dict["reviews_submitted_count"])
        let comments  = intOrZero(dict["review_comments_count"])
        let threads   = intOrZero(dict["review_thread_resolved_count"])

        let byRepoArr = (dict["by_repo"] as? [[String: Any]]) ?? []
        let byRepo: [RepoEntry] = byRepoArr.compactMap { entry in
            guard let repo = entry["repo"] as? String,
                  let r = intOrNil(entry["reviews"]),
                  let c = intOrNil(entry["comments"]),
                  let t = intOrNil(entry["threads"]) else { return nil }
            return RepoEntry(repo: repo, reviews: r, comments: c, threads: t)
        }

        let linkedArr = (dict["linked_prs"] as? [[String: Any]]) ?? []
        let linked: [LinkedPREntry] = linkedArr.compactMap { entry in
            guard let repo = entry["repo"] as? String,
                  let pr = intOrNil(entry["pr_number"]) else { return nil }
            let lid: String?
            if let s = entry["linked_linear_id"] as? String, !s.isEmpty {
                lid = s
            } else {
                lid = nil
            }
            return LinkedPREntry(repo: repo, prNumber: pr, linkedLinearID: lid)
        }

        return ReviewActivityResult(
            periodLabel: period,
            reviewsSubmittedCount: submitted,
            reviewCommentsCount: comments,
            reviewThreadResolvedCount: threads,
            byRepo: byRepo,
            linkedPRs: linked
        )
    }

    private static func intOrNil(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }

    private static func intOrZero(_ v: Any?) -> Int {
        intOrNil(v) ?? 0
    }
}
