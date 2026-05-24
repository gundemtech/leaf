import Foundation

/// Snapshot of workspace-vs-merge-base git delta + parsed remote info, read in-process
/// from the workspace `.git` directory. Powers the RESUME hero block's WIP signal line
/// and the "Diff with main" CTA.
///
/// Counts are derived from `git rev-list --left-right --count HEAD...<mergeBase>` and
/// `git status --porcelain --untracked-files=no`. `mergeBase` is the resolved default
/// remote ref (e.g. `origin/main`), `nil` when no upstream is resolvable.
public struct GitDeltaSnapshot: Equatable, Hashable, Sendable {
    public let commitsAhead: Int
    public let commitsBehind: Int
    public let uncommittedCount: Int
    public let mergeBase: String?
    public let remote: GitRemoteRef?

    public init(
        commitsAhead: Int,
        commitsBehind: Int,
        uncommittedCount: Int,
        mergeBase: String? = nil,
        remote: GitRemoteRef? = nil
    ) {
        self.commitsAhead = commitsAhead
        self.commitsBehind = commitsBehind
        self.uncommittedCount = uncommittedCount
        self.mergeBase = mergeBase
        self.remote = remote
    }
}

/// Parsed `origin` remote URL — supports github.com ssh + https forms, structured for
/// composing browser URLs ("Diff with main" CTA: `https://<host>/<owner>/<repo>/compare/...`).
public struct GitRemoteRef: Equatable, Hashable, Sendable {
    public let host: String
    public let owner: String
    public let repo: String

    public init(host: String, owner: String, repo: String) {
        self.host = host
        self.owner = owner
        self.repo = repo
    }
}
