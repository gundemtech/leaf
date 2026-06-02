import Foundation

/// Phase 2.4 — strategy for translating raw FSEvents (path + flag bitmask) into
/// a `RawEvent` for writing to `events`. The ignore-list implementation, L4/L5 mapping,
/// and coalesce dedup are moat (`FSEventsRouterProd`); the public side only knows
/// the contract + Stub.
///
/// `async` — Prod uses mutable coalesce state (a per-actor LRU map `[String: Date]`)
/// and is implemented as an actor. Stub returns synchronously via an async no-op.
public protocol FSEventsRouting: Sendable {
    func route(
        path: String,
        flags: UInt32,
        watchedFolders: [WatchedFolder],
        now: Date
    ) async -> FSEventsRouteResult
}

/// Result of routing a single FSEvents callback path.
public enum FSEventsRouteResult: Sendable {
    /// Pass-through to EventWriter — will be written to `events`.
    case event(RawEvent)
    /// Filtered — known reason (ignore-list match, coalesce, granularity stripped).
    /// Logged at `debug` level, not warning.
    case filtered(reason: String)
    /// Unknown flag bitmask — no explicit mapping for this combination of FSEvent flags.
    /// Skip silently (not treated as an error; FSEvents flags expand between macOS versions).
    case unknown
}

/// Default-flow stub for CI and dev-without-moat builds: always `.filtered`.
/// FSEventsCollector still works (the callback writes/reads), but events
/// are not written. This is convenient for lifecycle tests without a moat dependency.
public struct StubFSEventsRouter: FSEventsRouting {
    public init() {}

    public func route(
        path: String,
        flags: UInt32,
        watchedFolders: [WatchedFolder],
        now: Date
    ) async -> FSEventsRouteResult {
        .filtered(reason: "stub")
    }
}
