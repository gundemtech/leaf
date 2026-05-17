import Foundation
import GRDB

/// Phase Track-1 D3 — per-detector progress cursor reads + advances.
///
/// `detector_offsets` is pre-seeded by M014 with three rows
/// (`decision` / `open_question` / `blocker_pattern`); cursor advance is
/// always an UPDATE — INSERT path not exercised in the per-event pipeline.
public enum DetectorOffsetsStore {
    public static func cursor(detectorKind: String, in db: GRDB.Database) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql:
                "SELECT cursor_event_id FROM detector_offsets WHERE detector_kind = ?",
            arguments: [detectorKind]) ?? 0
    }

    public static func advance(
        detectorKind: String,
        toEventID: Int64,
        nowMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                    UPDATE detector_offsets
                       SET cursor_event_id = ?, last_run_at_ms = ?
                     WHERE detector_kind = ?
                """, arguments: [toEventID, nowMs, detectorKind])
    }
}
