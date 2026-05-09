import Foundation

/// Phase Track-1 D2 — public value type for `event_links` row.
/// Used by `EventLinksStore.linksFrom(eventID:in:)` reader API + future D3 detector
/// surfaces. SQL-level identity is the composite PK
/// (fromEventID, linkKind, targetRef) — `EventLink` carries them as fields.
public struct EventLink: Codable, Sendable, Hashable {
    public let fromEventID: Int64
    public let linkKind: String
    public let targetKind: String
    public let targetRef: String
    public let confidence: Double
    public let createdAtMs: Int64

    public init(
        fromEventID: Int64,
        linkKind: String,
        targetKind: String,
        targetRef: String,
        confidence: Double,
        createdAtMs: Int64
    ) {
        self.fromEventID = fromEventID
        self.linkKind = linkKind
        self.targetKind = targetKind
        self.targetRef = targetRef
        self.confidence = confidence
        self.createdAtMs = createdAtMs
    }
}
