import Foundation

/// Phase 5.3.E — return type for `RotationFetchService.tick()`. Aggregate counts
/// across one fetch+install pass. Surface for logging + (future) Privacy Dashboard.
///
/// `skipped` blobs are NOT acked (peek-fail / decode-fail / install-fail) → relay
/// TTL purges or admin re-POST recovers.
public struct RotationFetchOutcome: Sendable, Hashable {
    /// Total blobs returned by relay's GET drain.
    public let fetched: Int
    /// `.rotation` blobs successfully decoded + installed.
    public let installed: Int
    /// `.tombstone` blobs successfully decoded + applied (self marked removed).
    public let tombstoneApplied: Int
    /// Blobs skipped due to peek/decode/install failure.
    public let skipped: Int

    public init(fetched: Int, installed: Int, tombstoneApplied: Int, skipped: Int) {
        self.fetched = fetched
        self.installed = installed
        self.tombstoneApplied = tombstoneApplied
        self.skipped = skipped
    }

    public static let empty = Self(
        fetched: 0, installed: 0, tombstoneApplied: 0, skipped: 0
    )
}
