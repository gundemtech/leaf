import Foundation

/// Track-9 T1 — derived snapshot of the most-recent observed `gh_commit_pushed`
/// event within a maxAge window. Consumed by Track-9 T7 WhereStoppedSnapshot
/// 4-line layout ("Last commit: <subject>") and downstream Analytics surfaces.
///
/// Subject is the commit message first line (Layer B GitHub collector already
/// captures only the first line per ADR-010 walkback). Branch is Optional —
/// some GitHub Event API payloads (PushEvent stripped shape) omit `branch`.
public struct RecentCommitSnapshot: Equatable, Hashable, Sendable {
    public let subject: String
    public let branch: String?
    public let atMs: Int64

    public init(subject: String, branch: String?, atMs: Int64) {
        self.subject = subject
        self.branch = branch
        self.atMs = atMs
    }
}
