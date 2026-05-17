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
    public static func insertOpenIfAbsent(
        targetKind: String,
        targetRef: String,
        blockerKind: String,
        excerpt: String?,
        detectedByEventID: Int64?,
        startedAtMs: Int64,
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
                targetKind, targetRef, blockerKind, excerpt,
                detectedByEventID, startedAtMs,
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
