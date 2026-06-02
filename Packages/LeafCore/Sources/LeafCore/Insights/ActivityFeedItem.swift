import Foundation

/// Track-10 T5 — per-event substrate row from `DerivedInsights.recentActivityFeed(since:limit:)`.
/// Metadata only (eventKind discriminator + actor display + target ref/title + repo hint).
/// Body fields (comment_body, note_body, email_subject, file_contents, raw_prompt,
/// tool_input, tool_response, prompt) NEVER read — the sentinel-injection regression test
/// `LEAKED_SENTINEL_T5_RECENT_FEED` in RelayBodyLeakageTests guards walkback discipline.
public struct ActivityFeedItem: Sendable, Hashable, Codable {
    public let ts: Int64
    public let source: SinceSource
    public let eventKind: String
    public let actorDisplay: String?
    public let actorIsMe: Bool
    public let targetTitle: String?
    public let targetRef: String?
    public let repoHint: String?
    public let sourceURL: URL?

    public init(
        ts: Int64,
        source: SinceSource,
        eventKind: String,
        actorDisplay: String? = nil,
        actorIsMe: Bool = false,
        targetTitle: String? = nil,
        targetRef: String? = nil,
        repoHint: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.ts = ts
        self.source = source
        self.eventKind = eventKind
        self.actorDisplay = actorDisplay
        self.actorIsMe = actorIsMe
        self.targetTitle = targetTitle
        self.targetRef = targetRef
        self.repoHint = repoHint
        self.sourceURL = sourceURL
    }
}

public enum SinceSource: String, Sendable, Hashable, Codable, CaseIterable {
    case linear
    case github
    case slack
    case detection
}
