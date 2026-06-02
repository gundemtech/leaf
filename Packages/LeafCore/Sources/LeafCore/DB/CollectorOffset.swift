import Foundation

/// Phase 2.3 — position of a tail-read collector within its source.
/// `(collectorID, sourceID)` — composite PK. For Claude Code:
/// `collectorID == CollectorID.claudeCodeJSONL`, `sourceID == abs path to .jsonl`.
///
/// `byteOffset` — position of the next unread byte (== EOF when the file is
/// fully read). `inode`/`size`/`lastModifiedMs` — fingerprint for rotation
/// detection: on `inode != stored.inode` or `size < stored.byteOffset`
/// (truncate / replay) the collector resets the offset to 0.
public struct CollectorOffset: Sendable, Hashable {
    public let collectorID: String
    public let sourceID: String
    public let byteOffset: Int64
    public let inode: Int64?
    public let size: Int64
    public let lastModifiedMs: Int64
    public let updatedMs: Int64

    public init(
        collectorID: String,
        sourceID: String,
        byteOffset: Int64,
        inode: Int64?,
        size: Int64,
        lastModifiedMs: Int64,
        updatedMs: Int64
    ) {
        self.collectorID = collectorID
        self.sourceID = sourceID
        self.byteOffset = byteOffset
        self.inode = inode
        self.size = size
        self.lastModifiedMs = lastModifiedMs
        self.updatedMs = updatedMs
    }
}
