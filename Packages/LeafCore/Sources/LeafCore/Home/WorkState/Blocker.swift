import Foundation

/// A blocking state on a Linear issue, GitHub PR, or other tracked target.
/// Sourced from M014 `blockers` table via `DerivedInsights.openBlockers()`.
/// `resolvedAtMs == nil` means the blocker is currently open.
public struct Blocker: Equatable, Hashable, Sendable {
    public let id: Int64
    public let targetKind: BlockerTargetKind
    public let targetRef: String
    public let blockerKind: BlockerKind
    public let excerpt: String
    public let startedAtMs: Int64
    public let resolvedAtMs: Int64?

    public init(
        id: Int64,
        targetKind: BlockerTargetKind,
        targetRef: String,
        blockerKind: BlockerKind,
        excerpt: String,
        startedAtMs: Int64,
        resolvedAtMs: Int64?
    ) {
        self.id = id
        self.targetKind = targetKind
        self.targetRef = targetRef
        self.blockerKind = blockerKind
        self.excerpt = excerpt
        self.startedAtMs = startedAtMs
        self.resolvedAtMs = resolvedAtMs
    }
}
