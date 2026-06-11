import Foundation

/// Use-case rebuild Track A1 — one self-authored commit read from a local
/// repo's history. Subjects/bodies are the user's own writing (ADR-010
/// self-authored labels); teammates' commits never pass the reader contract.
public struct GitCommitRecord: Sendable, Hashable {
  public let sha: String
  public let subject: String
  /// Trailing body paragraphs (nil when the commit is subject-only). Capped by
  /// the implementation; LeafCore never re-caps.
  public let body: String?
  public let committedAtMs: Int64
  /// Checked-out branch at read time (HEAD-reachable history only — the
  /// reader does not walk other branches).
  public let branch: String?
  public let remote: GitRemoteRef?

  public init(
    sha: String,
    subject: String,
    body: String?,
    committedAtMs: Int64,
    branch: String?,
    remote: GitRemoteRef?
  ) {
    self.sha = sha
    self.subject = subject
    self.body = body
    self.committedAtMs = committedAtMs
    self.branch = branch
    self.remote = remote
  }
}

/// Reads self-authored commits from a local repository. Implementations run
/// `git` subprocesses (LeafCorePrivate `ProdGitCommitLogReader` — command
/// shape and format string are moat); the stub returns nothing so substrate
/// builds still exercise the collector wiring.
public protocol GitCommitLogReading: Sendable {
  /// Commits authored by the repo's configured user, newest first.
  /// `sinceMs == nil` → implementation-defined initial window (90 days).
  func selfAuthoredCommits(
    repoPath: String,
    sinceMs: Int64?,
    limit: Int
  ) async -> [GitCommitRecord]
}

public struct StubGitCommitLogReader: GitCommitLogReading {
  public init() {}
  public func selfAuthoredCommits(
    repoPath: String, sinceMs: Int64?, limit: Int
  ) async -> [GitCommitRecord] { [] }
}

/// Factory mirrors `GitDeltaReaderFactory` (write-once-read-many).
/// LeafCorePrivate bootstrap registers `ProdGitCommitLogReader.init`; tests
/// and stub builds fall back to `StubGitCommitLogReader`.
public enum GitCommitLogReaderFactory {
  nonisolated(unsafe) private static var provider: (@Sendable () -> any GitCommitLogReading)?

  public static func register(
    _ provider: @escaping @Sendable () -> any GitCommitLogReading
  ) {
    Self.provider = provider
  }

  public static func make() -> any GitCommitLogReading {
    provider?() ?? StubGitCommitLogReader()
  }

  /// Test-only hook to clear registration between tests.
  public static func resetForTests() {
    provider = nil
  }
}
