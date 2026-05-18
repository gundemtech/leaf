import Foundation

public struct TeammateMatch: Equatable, Hashable, Sendable {
    public let memberID: String
    public let displayName: String
    public let currentApp: String?
    public let durationSec: Int
    public let confidence: MatchConfidence
    public let contextLabel: String
    public let lastActivityAtMs: Int64

    public init(
        memberID: String, displayName: String, currentApp: String?, durationSec: Int,
        confidence: MatchConfidence, contextLabel: String, lastActivityAtMs: Int64
    ) {
        self.memberID = memberID
        self.displayName = displayName
        self.currentApp = currentApp
        self.durationSec = durationSec
        self.confidence = confidence
        self.contextLabel = contextLabel
        self.lastActivityAtMs = lastActivityAtMs
    }
}

public enum MatchConfidence: String, Equatable, Hashable, Sendable, CaseIterable {
    case onSameLinearIssue
    case onSameBranch
    case onAdjacentBranch

    /// Sort priority — lower = higher confidence (front of list).
    public var sortRank: Int {
        switch self {
        case .onSameLinearIssue: return 0
        case .onSameBranch: return 1
        case .onAdjacentBranch: return 2
        }
    }
}

public enum MatchRule: String, Equatable, Hashable, Sendable {
    case hierarchical
}
