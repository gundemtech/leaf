import Foundation

/// Track-10 T5 — UI-tier row composed by `InsightsReader.refresh()` from raw
/// `ActivityFeedItem` substrate rows via per-event-kind verb + severity mapping.
/// Reuses Track-9 T8 `InboxSeverity` — single shared severity model across NEEDS
/// YOU + SINCE blocks.
///
/// Identity model: NO UUID. `uniqueKey: String` derived from content composition
/// (`source + verb + tsMs + sourceMeta`) for SwiftUI ForEach stable identity
/// across refresh cycles. Content-Equatable + content-Hashable — identical refresh
/// content produces identical snapshot hash → SwiftUI skips re-renders.
public struct SinceLastActiveItem: Sendable, Hashable {
    public let severity: InboxSeverity
    public let verb: String
    public let actorPrefix: String
    public let targetTitle: String
    public let sourceMeta: String
    public let tsMs: Int64
    public let source: SinceSource
    public let sourceURL: URL?

    public var uniqueKey: String {
        // `targetTitle` is part of the key: sourceMeta is frequently empty
        // after the meta-dedup (ref repeating the title is dropped), so
        // same-millisecond events with the same verb (Linear bulk status
        // changes, Slack aggregates) would otherwise collide in ForEach.
        "\(source.rawValue)-\(verb)-\(tsMs)-\(targetTitle)-\(sourceMeta)"
    }

    public init(
        severity: InboxSeverity,
        verb: String,
        actorPrefix: String,
        targetTitle: String,
        sourceMeta: String,
        tsMs: Int64,
        source: SinceSource,
        sourceURL: URL?
    ) {
        self.severity = severity
        self.verb = verb
        self.actorPrefix = actorPrefix
        self.targetTitle = targetTitle
        self.sourceMeta = sourceMeta
        self.tsMs = tsMs
        self.source = source
        self.sourceURL = sourceURL
    }
}

extension SinceLastActiveItem {
    /// Track-10 T5 — compose UI-tier row from substrate `ActivityFeedItem`.
    /// Returns `nil` for event_kinds outside the allow-listed verb map.
    public static func compose(from feed: ActivityFeedItem) -> SinceLastActiveItem? {
        guard let mapping = verbMap[feed.eventKind] else { return nil }
        let actorPrefix: String = {
            if feed.source == .detection { return "" }
            if feed.actorIsMe { return "you" }
            return feed.actorDisplay ?? "@teammate"
        }()
        let targetTitle = feed.targetTitle ?? feed.targetRef ?? "—"
        let sourceMeta = makeSourceMeta(feed: feed, targetTitle: targetTitle)
        return SinceLastActiveItem(
            severity: mapping.severity,
            verb: mapping.verb,
            actorPrefix: actorPrefix,
            targetTitle: targetTitle,
            sourceMeta: sourceMeta,
            tsMs: feed.ts,
            source: feed.source,
            sourceURL: feed.sourceURL
        )
    }

    // Track-10 T8 — Linear keys hoisted into `LinearActivityKinds` namespace;
    // SinceLastActiveItem reads from constants (single source of truth) so
    // downstream callers (StandupComposer) cannot drift apart.
    private static let verbMap: [String: (verb: String, severity: InboxSeverity)] = [
        LinearActivityKinds.statusTransitionStartedKind: ("started", .muted),
        LinearActivityKinds.statusTransitionCompletedKind: ("completed", .muted),
        LinearActivityKinds.statusTransitionCanceledKind: ("canceled", .muted),
        LinearActivityKinds.statusTransitionReopenedKind: ("reopened", .warn),
        "linear_comment_authored_to_me": ("commented on", .warn),
        "gh_commit_pushed": ("pushed", .muted),
        "gh_pr_opened": ("opened", .muted),
        "gh_pr_merged": ("merged", .muted),
        GitHubActivityKinds.prReviewAuthoredKind: ("reviewed", .muted),
        "gh_pr_review_requested": ("requested your review on", .warn),
        "slack_huddle_state_change": ("joined a huddle", .muted),
        "slack_mention_received_aggregate": ("mentioned you in", .warn),
        "open_question": ("open question:", .warn),
        "blocker": ("blocker:", .danger),
        // Feed spectrum (2026-06-11) — the substrate captures ~195 kinds and
        // the feed showed 9 of them. High-signal additions:
        "gh_issue_opened": ("opened issue", .muted),
        "gh_issue_closed": ("closed issue", .muted),
        "gh_release_published": ("published release", .muted),
        "gh_branch_created": ("created branch", .muted),
        "gh_tag_created": ("tagged", .muted),
        "gh_pr_review_comment_authored": ("commented on", .muted),
        "gh_issue_comment_authored": ("commented on", .muted),
        "gh_discussion_authored": ("started discussion", .muted),
        "linear_comment_authored": ("commented on", .muted),
        "linear_project_update_authored": ("posted project update", .muted),
        // Synthetic sub-discriminators (mirror linear_status_transition.*):
        // the mapper picks direction from from/to priority ints.
        "linear_priority_changed.raised": ("raised priority of", .muted),
        "linear_priority_changed.lowered": ("lowered priority of", .muted),
        // Assignee buckets — only self-relevant moves surface; third-party
        // shuffles are noise in MY feed.
        "linear_assignee_changed.picked_up": ("picked up", .muted),
        "linear_assignee_changed.handed_off": ("handed off", .muted),
    ]

    private static func makeSourceMeta(feed: ActivityFeedItem, targetTitle: String) -> String {
        // A ref that merely repeats the row title ("you pushed feature/x ·
        // feature/x · leaf") is dropped — the meta line carries only context
        // the title doesn't already show.
        let ref = feed.targetRef.flatMap { ($0.isEmpty || $0 == targetTitle) ? nil : $0 }
        switch feed.source {
        case .github:
            let parts = [ref, feed.repoHint]
                .compactMap { ($0?.isEmpty == false) ? $0 : nil }
            return parts.joined(separator: " · ")
        case .linear:
            return ref ?? ""
        case .slack:
            return ref ?? ""
        case .detection:
            // Both `blocker` and `open_question` rows come from the local
            // detection pipeline (M014 tables).
            return "Detected by Leaf"
        }
    }
}

