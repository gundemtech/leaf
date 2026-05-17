import Foundation
import GRDB

/// Phase Track-1 D3 — `blockers` writer.
///
/// `insertOpenIfAbsent` relies on the partial unique index `idx_blockers_open`
/// which constrains `(target_kind, target_ref)` only WHERE `resolved_at_ms IS
/// NULL`. INSERT OR IGNORE silently drops the second open row for the same
/// target. Resolved rows are excluded from uniqueness — re-opening after a
/// resolve is intentionally allowed (D3 §3.1).
///
/// `resolve` is the symmetric exit; it lands its first real callsite in the
/// scheduled-detector commit (LinearStuck auto-resolve) but is shipped here
/// so the store surface is whole.
public enum BlockersStore {
    /// Per-row input for ``insertOpenIfAbsent(_:in:)``. The 6 columns mirror
    /// the writable subset of the `blockers` schema (resolution columns are
    /// untouched by insert — they live on `resolve(...)`). Grouped struct
    /// keeps the call signature digestible and matches the detector-pipeline
    /// callsite shape (1 instance per detector hit).
    public struct OpenBlockerInput: Sendable {
        public let targetKind: String
        public let targetRef: String
        public let blockerKind: String
        public let excerpt: String?
        public let detectedByEventID: Int64?
        public let startedAtMs: Int64

        public init(
            targetKind: String,
            targetRef: String,
            blockerKind: String,
            excerpt: String?,
            detectedByEventID: Int64?,
            startedAtMs: Int64
        ) {
            self.targetKind = targetKind
            self.targetRef = targetRef
            self.blockerKind = blockerKind
            self.excerpt = excerpt
            self.detectedByEventID = detectedByEventID
            self.startedAtMs = startedAtMs
        }
    }

    public static func insertOpenIfAbsent(
        _ input: OpenBlockerInput,
        in db: GRDB.Database
    ) throws -> Bool {
        try db.execute(
            sql: """
                    INSERT OR IGNORE INTO blockers
                        (target_kind, target_ref, blocker_kind, blocker_excerpt,
                         detected_by_event_id, started_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                input.targetKind, input.targetRef, input.blockerKind, input.excerpt,
                input.detectedByEventID, input.startedAtMs,
            ])
        return db.changesCount > 0
    }

    public static func resolve(
        targetKind: String,
        targetRef: String,
        resolvedAtMs: Int64,
        resolvedByEventID: Int64?,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                    UPDATE blockers
                       SET resolved_at_ms = ?, resolved_by_event_id = ?
                     WHERE target_kind = ? AND target_ref = ?
                       AND resolved_at_ms IS NULL
                """, arguments: [resolvedAtMs, resolvedByEventID, targetKind, targetRef])
    }
}
