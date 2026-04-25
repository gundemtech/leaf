import Foundation

/// Phase 2.3 — позиция tail-read collector'а в его источнике.
/// `(collectorID, sourceID)` — composite PK. Для Claude Code:
/// `collectorID == CollectorID.claudeCodeJSONL`, `sourceID == abs path к .jsonl`.
///
/// `byteOffset` — позиция следующего непрочитанного байта (== EOF когда файл
/// дочитан). `inode`/`size`/`lastModifiedMs` — fingerprint для rotation
/// detection: при `inode != stored.inode` или `size < stored.byteOffset`
/// (truncate / replay) collector сбрасывает offset в 0.
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
