import Foundation

/// Phase Track-4 S3 — discrimination + coalesce gate под Trash FSEvents.
/// Distinguishes `.added` (single file dragged to trash) vs `.emptied`
/// (burst of removals after Empty Trash). Coalesces emissions within window
/// (default 2s mirror S1 SpaceTransitionCoalescer) чтобы Spotlight bursts
/// не triplicate'или.
///
/// **Filename only** — никогда не читает file contents (ADR-010 Won't-list).
public struct TrashMatcher: Sendable {
    public enum Emission: Sendable, Hashable { case added, emptied }

    private var lastEmitMs: Int64 = 0
    private let coalesceWindowMs: Int64

    public init(coalesceWindowMs: Int64 = 2_000) {
        self.coalesceWindowMs = coalesceWindowMs
    }

    /// Heuristic: large removed-burst (>10) сильно превосходит added → empty;
    /// otherwise если addedCount > 0 → added. Coalesce drops emissions within
    /// coalesceWindowMs of prior emit.
    ///
    /// **Known false-negative (I5 code review)**: batch like
    /// `addedCount=6, removedCount=12` (both > 10 trigger, but ratio<2×) emits
    /// `.added` despite being empty-like. Acceptable best-effort — Empty
    /// Trash gestures typically remove 50+ items single-shot, ratio holds.
    public mutating func observe(
        addedCount: Int,
        removedCount: Int,
        nowMs: Int64
    ) -> Emission? {
        guard (nowMs - lastEmitMs) > coalesceWindowMs else { return nil }
        let emission: Emission?
        if removedCount > 10 && removedCount > addedCount * 2 {
            emission = .emptied
        } else if addedCount > 0 {
            emission = .added
        } else {
            emission = nil
        }
        if emission != nil { lastEmitMs = nowMs }
        return emission
    }
}
