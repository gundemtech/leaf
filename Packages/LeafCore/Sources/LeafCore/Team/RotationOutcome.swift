import Foundation

/// Phase 5.3.D — result of `KeyRotationService.removeMember(...)` or
/// `.resumePendingPosts()`. `postedCount + pendingCount == totalCount`. For
/// resume calls that drain rows from multiple historical events, `newKeyID` and
/// `priorKeyID` are empty strings (the outcome aggregates across keys).
public struct RotationOutcome: Sendable, Hashable {
    public let newKeyID: String
    public let priorKeyID: String
    public let postedCount: Int
    public let pendingCount: Int
    public let totalCount: Int

    public init(
        newKeyID: String,
        priorKeyID: String,
        postedCount: Int,
        pendingCount: Int,
        totalCount: Int
    ) {
        self.newKeyID = newKeyID
        self.priorKeyID = priorKeyID
        self.postedCount = postedCount
        self.pendingCount = pendingCount
        self.totalCount = totalCount
    }
}
