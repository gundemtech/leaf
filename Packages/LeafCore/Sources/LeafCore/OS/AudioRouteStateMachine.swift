import Foundation

/// Phase Track-4 S3 — pure transition detector для audio routing category.
/// Mirror Focus/Meeting state-machine pattern: first observation primes state
/// без emit'а (avoid re-emitting "transition to builtin" на каждом agent restart);
/// subsequent same-category observations no-emit; category change emits the
/// new category.
public struct AudioRouteStateMachine: Sendable, Hashable {
    private var lastCategory: AudioRouteCategory?

    public init() {}

    /// Returns the destination category iff the observation represents
    /// a transition (i.e. prior state was non-nil AND differs).
    public mutating func observe(_ category: AudioRouteCategory) -> AudioRouteCategory? {
        defer { lastCategory = category }
        guard let prior = lastCategory else { return nil }
        return prior == category ? nil : category
    }
}
