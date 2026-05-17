import Foundation

/// A decision logged by Track-1 D3 `DecisionDetector`. Sourced from M014
/// `decisions` table via `DerivedInsights.recentDecisions(period:limit:)`.
public struct Decision: Equatable, Hashable, Sendable {
    public let id: Int64
    public let excerpt: String
    public let topicKeywords: [String]
    public let confidence: Double
    public let detectedAtMs: Int64
    public let sourceEventId: Int64?

    public init(
        id: Int64,
        excerpt: String,
        topicKeywords: [String],
        confidence: Double,
        detectedAtMs: Int64,
        sourceEventId: Int64?
    ) {
        self.id = id
        self.excerpt = excerpt
        self.topicKeywords = topicKeywords
        self.confidence = confidence
        self.detectedAtMs = detectedAtMs
        self.sourceEventId = sourceEventId
    }
}
