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

    public init(
        linearID: String? = nil, branch: String? = nil, repo: String? = nil,
        workspacePath: String? = nil
    ) {
        self.linearID = linearID
        self.branch = branch
        self.repo = repo
        self.workspacePath = workspacePath
    }

    public var isEmpty: Bool {
        linearID == nil && branch == nil && repo == nil && workspacePath == nil
    }
}
