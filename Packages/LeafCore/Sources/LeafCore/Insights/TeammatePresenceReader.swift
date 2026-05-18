import Foundation

/// Returns most-recent snapshot per teammate where `lastActivityAtMs` is within the
/// requested freshness window. Returns `[]` when relay is disconnected, no teammates
/// exist, or `presence_history` is not yet migrated (pre-Phase 5.4).
public protocol TeammatePresenceReader: Sendable {
    func recentTeammateSnapshots(maxAge: TimeInterval, now: Date) throws -> [TeammateSnapshot]
}

public struct StubTeammatePresenceReader: TeammatePresenceReader {
    public init() {}

    public func recentTeammateSnapshots(maxAge: TimeInterval, now: Date) throws -> [TeammateSnapshot] {
        []
    }
}

/// Factory mirrors `DerivedInsightsFactory` — Phase 5.4 will call
/// `register(DBTeammatePresenceReader.init)` from LeafCorePrivate startup to light up
/// reads against `presence_history`. P1 always resolves to `StubTeammatePresenceReader`.
public enum TeammatePresenceReaderFactory {
    // Concept mirrors `DerivedInsightsFactory`: read-many-write-once, set at app start.
    nonisolated(unsafe) private static var provider: (@Sendable (Database) -> any TeammatePresenceReader)?

    public static func register(
        _ provider: @escaping @Sendable (Database) -> any TeammatePresenceReader
    ) {
        Self.provider = provider
    }

    public static func make(database: Database) -> any TeammatePresenceReader {
        provider?(database) ?? StubTeammatePresenceReader()
    }

    /// Test-only hook to clear registration between tests.
    public static func resetForTests() {
        provider = nil
    }
}
