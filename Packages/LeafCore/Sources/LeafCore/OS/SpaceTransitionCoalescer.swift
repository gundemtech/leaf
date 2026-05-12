import Foundation

/// Phase Track-4 S1 — drops `space_switched` emissions within
/// `coalesceWindowMs` of the previous EMITTED tick. Rapid Mission-Control
/// gesture sweeps (one swipe takes ~50-200ms per Space) collapse to a single
/// event; deliberate single switches always emit. Collector composes it at the
/// OS boundary.
public struct SpaceTransitionCoalescer: Sendable, Hashable {
    public let coalesceWindowMs: Int64
    private var lastEmitMs: Int64?

    public init(coalesceWindowMs: Int64) {
        self.coalesceWindowMs = coalesceWindowMs
    }

    /// Returns `true` if the caller should emit this observation, `false` to
    /// drop. State updates only on emit (`true`) — repeated `observe` calls in
    /// the same window all return `false` and keep `lastEmitMs` unchanged.
    public mutating func observe(nowMs: Int64) -> Bool {
        guard let prior = lastEmitMs else {
            lastEmitMs = nowMs
            return true
        }
        if nowMs - prior <= coalesceWindowMs { return false }
        lastEmitMs = nowMs
        return true
    }
}
