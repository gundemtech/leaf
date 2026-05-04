import Foundation

/// Provider bucket for an activity feed row. `local` covers `signal_type=attention`
/// app-switch events (Phase 2.1). `linear`/`github`/`slack` pull `signal_type=action|context`
/// rows by `payload.source`. `ai` covers `signal_type=aiCollaboration` (Phase 2.3 hooks).
/// `unknown` is a defensive bucket for events that pass through the mapper without a
/// recognized shape — UI can hide them or render generically.
public enum ActivityProvider: String, Sendable, Hashable, CaseIterable, Codable {
    case local, linear, github, slack, ai, unknown
}

/// One row in the chronological activity feed surfaced by the Activity tab.
///
/// Phase 4.10.A. Fields are derived per-event from `payload_json` via
/// `ActivityFeedMapper`. ADR-010: only safe identifying fields (issue keys, repo
/// names, channel names, status names, counts) are formatted into `primaryText` /
/// `secondaryText`. Bodies (commit messages, PR titles, comment text, file
/// names) are NEVER read by the mapper, even if a future collector accidentally
/// stores them.
public struct ActivityFeedEntry: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let timestamp: Date
    public let provider: ActivityProvider
    /// Raw `payload.event_kind` (or synthetic for attention rows). Stable
    /// identifier UI can use for icon mapping & filtering.
    public let eventKind: String
    /// User-facing primary line (e.g. `"ENG-1234 → In Review"`). Always present.
    public let primaryText: String
    /// Optional secondary metadata (project / repo / channel). `nil` when the
    /// event has no useful contextual field beyond `primaryText`.
    public let secondaryText: String?
    /// Bundle identifier for `.local` rows (so UI can resolve a display name +
    /// icon via `AppNameResolver`). `nil` for integrations.
    public let bundleID: String?
    /// Number of raw rows this entry represents after coalescing consecutive
    /// duplicates (same provider/eventKind/primaryText/secondaryText/bundleID).
    /// `1` when no merge happened. UI renders a `× N` suffix when `> 1`.
    public let mergedCount: Int

    public init(
        id: Int64,
        timestamp: Date,
        provider: ActivityProvider,
        eventKind: String,
        primaryText: String,
        secondaryText: String? = nil,
        bundleID: String? = nil,
        mergedCount: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.eventKind = eventKind
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.bundleID = bundleID
        self.mergedCount = mergedCount
    }

    /// Stable identity used to coalesce consecutive duplicate rows. Two
    /// entries adjacent in the feed with the same key represent the same
    /// "thing happening" (e.g. the user toggling between two apps repeatedly,
    /// or Claude Code invoking the same Bash tool back to back) and should
    /// appear as one row in the UI.
    public var coalesceKey: String {
        "\(provider.rawValue)|\(eventKind)|\(bundleID ?? "")|\(primaryText)|\(secondaryText ?? "")"
    }

    /// Walk a chronological feed (any order; dedup is positional) and merge
    /// each run of identical `coalesceKey` rows into a single entry. The
    /// merged entry keeps the latest timestamp and the leading `id`, with
    /// `mergedCount` set to the run length. Rows with different keys pass
    /// through unchanged.
    public static func coalesceConsecutive(_ entries: [ActivityFeedEntry]) -> [ActivityFeedEntry] {
        guard !entries.isEmpty else { return [] }
        var result: [ActivityFeedEntry] = []
        result.reserveCapacity(entries.count)
        var current = entries[0]
        for next in entries.dropFirst() {
            if next.coalesceKey == current.coalesceKey {
                // Run continues — bump count, keep the freshest timestamp
                // (entries are typically descending, but be order-agnostic).
                let newest = max(current.timestamp, next.timestamp)
                current = ActivityFeedEntry(
                    id: current.id,
                    timestamp: newest,
                    provider: current.provider,
                    eventKind: current.eventKind,
                    primaryText: current.primaryText,
                    secondaryText: current.secondaryText,
                    bundleID: current.bundleID,
                    mergedCount: current.mergedCount + 1
                )
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }
}
