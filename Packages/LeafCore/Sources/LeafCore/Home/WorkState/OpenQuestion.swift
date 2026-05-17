import Foundation

/// A question raised by the user in chat / comments / PRs that Track-1 D3
/// `OpenQuestionDetector` captured. Sourced from M014 `open_questions` table.
public struct OpenQuestion: Equatable, Hashable, Sendable {
    public let id: Int64
    public let excerpt: String
    public let alternatives: [String]
    public let contextRef: ContextRef?
    public let openedAtMs: Int64
    public let resolvedAtMs: Int64?
    public let resolvedBySourceEventId: Int64?

    public init(
        id: Int64,
        excerpt: String,
        alternatives: [String],
        contextRef: ContextRef?,
        openedAtMs: Int64,
        resolvedAtMs: Int64?,
        resolvedBySourceEventId: Int64?
    ) {
        self.id = id
        self.excerpt = excerpt
        self.alternatives = alternatives
        self.contextRef = contextRef
        self.openedAtMs = openedAtMs
        self.resolvedAtMs = resolvedAtMs
        self.resolvedBySourceEventId = resolvedBySourceEventId
    }
}
