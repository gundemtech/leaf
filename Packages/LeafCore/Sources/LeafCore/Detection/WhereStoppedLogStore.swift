import Foundation
import GRDB

/// Phase Track-1 D3 — append-only writer/reader for `where_stopped_log`.
///
/// `WhereStoppedDeriver` (scheduled detector) emits a `WhereStoppedOutput`
/// snapshot when an idle window crosses its threshold; this store persists
/// the snapshot so downstream surfaces (MCP `leaf_current_work` + UI) can
/// render "where I left off" without recomputing.
///
/// Append-only by design — historical snapshots are valuable context for
/// "what was I doing yesterday" queries and there is no UPDATE path.
public enum WhereStoppedLogStore {
    public static func append(_ output: WhereStoppedOutput,
                              generatedAtMs: Int64,
                              in db: GRDB.Database) throws {
        // Encode WIP signals to JSON for column storage. Encoding failure is
        // non-fatal: the row still records excerpt + anchor, signals just
        // round-trip as NULL (consumer treats as "no WIP info available").
        let wipJSON = (try? String(
            data: JSONEncoder().encode(output.wipSignals),
            encoding: .utf8
        ))
        try db.execute(sql: """
            INSERT INTO where_stopped_log
                (generated_at_ms, anchor_event_id, excerpt, wip_signals_json)
            VALUES (?, ?, ?, ?)
        """, arguments: [generatedAtMs, output.anchorEventID, output.excerpt, wipJSON])
    }

    /// Most-recent snapshot by `generated_at_ms`. Returns nil on empty log.
    public static func latest(in db: GRDB.Database) throws -> Row? {
        try Row.fetchOne(db, sql: """
            SELECT id, generated_at_ms, anchor_event_id, excerpt, wip_signals_json
              FROM where_stopped_log
             ORDER BY generated_at_ms DESC
             LIMIT 1
        """)
    }
}
