import Foundation

/// Phase Track-4 S3 — delta detector над `NSPasteboard.general.changeCount`.
/// First observation primes lastCount без emit'а (avoid spam'а на agent
/// boot когда current changeCount уже большой). Subsequent observation
/// emits raw delta if positive.
///
/// **Content никогда не материализуется** (ADR-010 Won't-list — clipboard
/// → count only). `pasteboardItems` / `string(forType:)` не вызываются —
/// зашитая дисциплина на ClipboardCollector callsite.
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
