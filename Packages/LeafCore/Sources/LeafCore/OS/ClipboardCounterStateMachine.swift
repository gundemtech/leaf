import Foundation

/// Phase Track-4 S3 — delta detector over `NSPasteboard.general.changeCount`.
/// First observation primes lastCount without emitting (avoid spam at agent
/// boot when the current changeCount is already large). Subsequent observation
/// emits raw delta if positive.
///
/// **Content is never materialized** (ADR-010 Won't-list — clipboard
/// → count only). `pasteboardItems` / `string(forType:)` are not called —
/// discipline baked in at the ClipboardCollector callsite.
public struct ClipboardCounterStateMachine: Sendable, Hashable {
    private var lastCount: Int?

    public init() {}

    /// Returns positive delta (count - lastCount) iff prior was non-nil AND
    /// delta > 0. Negative/zero deltas return nil (count wraps or no change).
    public mutating func observe(_ count: Int) -> Int? {
        defer { lastCount = count }
        guard let prior = lastCount else { return nil }
        let delta = count - prior
        return delta > 0 ? delta : nil
    }
}
