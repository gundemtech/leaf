import Foundation

/// Caller's current work context — Linear issue, branch, repo, workspace path.
/// `isEmpty` distinguishes "nothing meaningful captured yet" from "we have presence
/// but it doesn't pin a task". `currentTaskIdentity()` returns `nil` only when the
/// underlying presence row is missing entirely.
public struct TaskIdentity: Equatable, Hashable, Sendable {
    public let linearID: String?
    public let branch: String?
    public let repo: String?
    public let workspacePath: String?
    /// Track-10 T2 — Linear workspace URL slug (e.g. "gundemtech"), read from
    /// `presence_state.linear.state_json $.workspace_slug`. Populated once Linear
    /// OAuth handshake completes a polling tick. Powers Linear-issue browser URL
    /// composition (`https://linear.app/<slug>/issue/<linearID>`) — Resume hero CTA
    /// hides when slug is `nil`. Default `nil` for stubs / pre-OAuth state.
    public let linearWorkspaceSlug: String?

    public init(
        linearID: String? = nil, branch: String? = nil, repo: String? = nil,
        workspacePath: String? = nil,
        linearWorkspaceSlug: String? = nil
    ) {
        self.linearID = linearID
        self.branch = branch
        self.repo = repo
        self.workspacePath = workspacePath
        self.linearWorkspaceSlug = linearWorkspaceSlug
    }

    public var isEmpty: Bool {
        linearID == nil && branch == nil && repo == nil && workspacePath == nil
            && linearWorkspaceSlug == nil
    }
}
