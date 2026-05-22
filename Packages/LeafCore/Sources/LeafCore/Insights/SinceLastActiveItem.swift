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
