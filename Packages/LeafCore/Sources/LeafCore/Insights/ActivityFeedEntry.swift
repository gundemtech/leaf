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

    public init(
        id: Int64,
        timestamp: Date,
        provider: ActivityProvider,
        eventKind: String,
        primaryText: String,
        secondaryText: String? = nil,
        bundleID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.eventKind = eventKind
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.bundleID = bundleID
    }
}
