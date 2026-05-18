import Foundation

/// Input row for `SameTaskMatcher`. Produced by `TeammatePresenceReader`
/// from the (Phase 5.4) `presence_history` table or from test fixtures.
public struct TeammateSnapshot: Equatable, Hashable, Sendable {
    public let memberID: String
    public let displayName: String
    public let linearID: String?
    public let branch: String?
    public let repo: String?
    public let currentApp: String?
    public let lastActivityAtMs: Int64

    public init(
        memberID: String, displayName: String, linearID: String?, branch: String?,
        repo: String?, currentApp: String?, lastActivityAtMs: Int64
    ) {
        self.memberID = memberID
        self.displayName = displayName
        self.linearID = linearID
        self.branch = branch
        self.repo = repo
        self.currentApp = currentApp
        self.lastActivityAtMs = lastActivityAtMs
    }
}
