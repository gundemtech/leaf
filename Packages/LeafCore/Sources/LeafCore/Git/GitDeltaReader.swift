import Foundation

/// Reads in-process git delta info for the caller's current workspace. Implementations
/// run subprocess invocations against `.git`; default fallback returns `nil`.
public protocol GitDeltaReader: Sendable {
    func read(forWorkspacePath path: String?) async -> GitDeltaSnapshot?
}

public struct StubGitDeltaReader: GitDeltaReader {
    public init() {}
    public func read(forWorkspacePath path: String?) async -> GitDeltaSnapshot? { nil }
}

/// Factory mirrors `TeammatePresenceReaderFactory` (write-once-read-many). LeafCorePrivate
/// bootstrap registers `ProdGitDeltaReader.init`; tests and stub builds fall back to
/// `StubGitDeltaReader`.
public enum GitDeltaReaderFactory {
    nonisolated(unsafe) private static var provider: (@Sendable () -> any GitDeltaReader)?

    public static func register(
        _ provider: @escaping @Sendable () -> any GitDeltaReader
    ) {
        Self.provider = provider
    }

    public static func make() -> any GitDeltaReader {
        provider?() ?? StubGitDeltaReader()
    }

    /// Test-only hook to clear registration between tests.
    public static func resetForTests() {
        provider = nil
    }
}
