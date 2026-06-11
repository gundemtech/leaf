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
        "\(source.rawValue)-\(verb)-\(tsMs)-\(sourceMeta)"
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

