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
    /// Carry C-T5-10 promoted to ship: how many substrate events collapsed
    /// into this row. `1` for un-coalesced rows (default). Rendered as
    /// `(×N)` suffix when `> 1` — mirrors NeedsYouRow `aggregatedCount`
    /// pattern. Coalesce signature = `(source, verb, targetTitle, sourceMeta)`
    /// applied by `SinceLastActiveItem.coalesce(_:)` post-compose.
    public let aggregatedCount: Int

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
        sourceURL: URL?,
        aggregatedCount: Int = 1
    ) {
        self.severity = severity
        self.verb = verb
        self.actorPrefix = actorPrefix
        self.targetTitle = targetTitle
        self.sourceMeta = sourceMeta
        self.tsMs = tsMs
        self.source = source
        self.sourceURL = sourceURL
        self.aggregatedCount = aggregatedCount
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
        let sourceMeta = makeSourceMeta(feed: feed)
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

    private static let verbMap: [String: (verb: String, severity: InboxSeverity)] = [
        "linear_status_transition.started": ("started", .muted),
        "linear_status_transition.completed": ("completed", .muted),
        "linear_status_transition.canceled": ("canceled", .muted),
        "linear_status_transition.reopened": ("reopened", .warn),
        "linear_comment_authored_to_me": ("commented on", .warn),
        "gh_commit_pushed": ("pushed", .muted),
        "gh_pr_opened": ("opened", .muted),
        "gh_pr_merged": ("merged", .muted),
        "gh_pr_review_authored": ("reviewed", .muted),
        "gh_pr_review_requested": ("requested your review on", .warn),
        "slack_huddle_state_change": ("joined a huddle", .muted),
        "slack_mention_received_aggregate": ("mentioned you in", .warn),
        "open_question": ("open question:", .warn),
        "blocker": ("blocker:", .danger),
    ]

    /// Track-10 T5 carry C-T5-10 (promoted to ship via fix-bundle). Coalesces
    /// duplicate substrate emissions (e.g. `LinearCollector` re-emits the same
    /// `linear_comment_authored_to_me` event when cursor advancement lags
    /// across ticks — observed ~5× rows for a single real comment on first
    /// GUN-47 flip smoke).
    ///
    /// Signature `(source, verb, targetTitle, sourceMeta)` preserves distinct
    /// targets (e.g. comments on different issues stay separate; D3 rows with
    /// distinct excerpts stay separate; PR opens vs PR merges stay separate)
    /// while collapsing same-target re-emissions. The merged row keeps the
    /// most recent `tsMs` and sums `aggregatedCount`.
    public static func coalesce(_ items: [SinceLastActiveItem]) -> [SinceLastActiveItem] {
        struct Key: Hashable {
            let source: SinceSource
            let verb: String
            let targetTitle: String
            let sourceMeta: String
        }
        var bucket: [Key: SinceLastActiveItem] = [:]
        var order: [Key] = []
        for item in items {
            let key = Key(
                source: item.source, verb: item.verb,
                targetTitle: item.targetTitle, sourceMeta: item.sourceMeta
            )
            if let existing = bucket[key] {
                bucket[key] = SinceLastActiveItem(
                    severity: existing.severity,
                    verb: existing.verb,
                    actorPrefix: existing.actorPrefix,
                    targetTitle: existing.targetTitle,
                    sourceMeta: existing.sourceMeta,
                    tsMs: max(existing.tsMs, item.tsMs),
                    source: existing.source,
                    sourceURL: existing.sourceURL ?? item.sourceURL,
                    aggregatedCount: existing.aggregatedCount + item.aggregatedCount
                )
            } else {
                bucket[key] = item
                order.append(key)
            }
        }
        // Preserve input order of first-seen keys, then re-sort by tsMs DESC
        // to keep the most-recent activity at the top — same order semantic
        // the caller expects from `recentActivityFeed`.
        let merged = order.compactMap { bucket[$0] }
        return merged.sorted { $0.tsMs > $1.tsMs }
    }

    private static func makeSourceMeta(feed: ActivityFeedItem) -> String {
        switch feed.source {
        case .github:
            let parts = [feed.targetRef, feed.repoHint]
                .compactMap { ($0?.isEmpty == false) ? $0 : nil }
            return parts.joined(separator: " · ")
        case .linear:
            return feed.targetRef ?? ""
        case .slack:
            return feed.targetRef ?? ""
        case .detection:
            // Both `blocker` (`blockers` table M014) and `open_question`
            // (`open_questions` table M014) live in the Track-1 D3 detection
            // substrate. Single shared label.
            return "Track-1 D3"
        }
    }
}

