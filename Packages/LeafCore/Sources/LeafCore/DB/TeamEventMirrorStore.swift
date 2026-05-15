import Foundation
import GRDB

/// Phase Track-5 S5 — CRUD over `team_events_mirror`. Static methods receive
/// raw `GRDB.Database` handle; caller wraps in `pool.write`/`pool.read`.
public struct TeamEventMirrorStore: Sendable {

    /// UPSERT row. `INSERT ... ON CONFLICT DO UPDATE` — idempotent on
    /// composite PK (workspace_id, event_id). Mirror tick may receive same
    /// Supabase row twice (cold-start + fresh poll); UPSERT keeps state
    /// consistent without raising errors.
    public static func upsert(_ row: TeamEventMirrorRow, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.TeamEventsMirror.tableName) (
                    \(Schema.TeamEventsMirror.eventID),
                    \(Schema.TeamEventsMirror.workspaceID),
                    \(Schema.TeamEventsMirror.senderPubkeyHex),
                    \(Schema.TeamEventsMirror.sourceKind),
                    \(Schema.TeamEventsMirror.kind),
                    \(Schema.TeamEventsMirror.plaintextPayloadJSON),
                    \(Schema.TeamEventsMirror.serverCreatedAtMs),
                    \(Schema.TeamEventsMirror.eventTsMs),
                    \(Schema.TeamEventsMirror.receivedAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(\(Schema.TeamEventsMirror.workspaceID), \(Schema.TeamEventsMirror.eventID))
                DO UPDATE SET
                    \(Schema.TeamEventsMirror.plaintextPayloadJSON) = excluded.\(Schema.TeamEventsMirror.plaintextPayloadJSON),
                    \(Schema.TeamEventsMirror.receivedAtMs)         = excluded.\(Schema.TeamEventsMirror.receivedAtMs)
                """,
            arguments: [
                row.eventID,
                row.workspaceID,
                row.senderPubkeyHex,
                row.source.rawValue,
                row.kind,
                row.plaintextPayloadJSON,
                row.serverCreatedAtMs,
                row.eventTsMs,
                row.receivedAtMs
            ]
        )
    }

    /// SELECT recent rows for a workspace, ordered server_created_at_ms DESC.
    public static func readRecent(
        workspaceID: String,
        limit: Int = 100,
        in db: GRDB.Database
    ) throws -> [TeamEventMirrorRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                \(selectAllSQL)
                WHERE \(Schema.TeamEventsMirror.workspaceID) = ?
                ORDER BY \(Schema.TeamEventsMirror.serverCreatedAtMs) DESC
                LIMIT ?
                """,
            arguments: [workspaceID, limit]
        )
        return rows.compactMap(Self.mapRow)
    }

    /// SELECT rows for a workspace + sender, ordered server_created_at_ms DESC.
    public static func readBySender(
        workspaceID: String,
        senderPubkeyHex: String,
        limit: Int = 100,
        in db: GRDB.Database
    ) throws -> [TeamEventMirrorRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                \(selectAllSQL)
                WHERE \(Schema.TeamEventsMirror.workspaceID) = ?
                  AND \(Schema.TeamEventsMirror.senderPubkeyHex) = ?
                ORDER BY \(Schema.TeamEventsMirror.serverCreatedAtMs) DESC
                LIMIT ?
                """,
            arguments: [workspaceID, senderPubkeyHex, limit]
        )
        return rows.compactMap(Self.mapRow)
    }

    /// MAX(server_created_at_ms) for incremental sync watermark. nil → cold bootstrap.
    public static func maxServerCreatedAtMs(
        workspaceID: String,
        in db: GRDB.Database
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT MAX(\(Schema.TeamEventsMirror.serverCreatedAtMs))
                FROM \(Schema.TeamEventsMirror.tableName)
                WHERE \(Schema.TeamEventsMirror.workspaceID) = ?
                """,
            arguments: [workspaceID]
        )
    }

    /// DELETE rows older than cutoff_ms. Returns count of rows removed.
    /// Used by `TeamEventMirrorRetentionPruner` (90d default; spec §12.2).
    public static func deleteOlderThan(
        cutoffMs: Int64,
        in db: GRDB.Database
    ) throws -> Int {
        try db.execute(
            sql: """
                DELETE FROM \(Schema.TeamEventsMirror.tableName)
                WHERE \(Schema.TeamEventsMirror.serverCreatedAtMs) < ?
                """,
            arguments: [cutoffMs]
        )
        return db.changesCount
    }

    // MARK: - Private

    private static let selectAllSQL = """
        SELECT \(Schema.TeamEventsMirror.eventID),
               \(Schema.TeamEventsMirror.workspaceID),
               \(Schema.TeamEventsMirror.senderPubkeyHex),
               \(Schema.TeamEventsMirror.sourceKind),
               \(Schema.TeamEventsMirror.kind),
               \(Schema.TeamEventsMirror.plaintextPayloadJSON),
               \(Schema.TeamEventsMirror.serverCreatedAtMs),
               \(Schema.TeamEventsMirror.eventTsMs),
               \(Schema.TeamEventsMirror.receivedAtMs)
        FROM \(Schema.TeamEventsMirror.tableName)
        """

    private static func mapRow(_ row: Row) -> TeamEventMirrorRow? {
        guard
            let eventID = row[Schema.TeamEventsMirror.eventID] as String?,
            let workspaceID = row[Schema.TeamEventsMirror.workspaceID] as String?,
            let senderPubkeyHex = row[Schema.TeamEventsMirror.senderPubkeyHex] as String?,
            let sourceRaw = row[Schema.TeamEventsMirror.sourceKind] as String?,
            let source = ShareSource(rawValue: sourceRaw),
            let kind = row[Schema.TeamEventsMirror.kind] as String?,
            let payloadJSON = row[Schema.TeamEventsMirror.plaintextPayloadJSON] as String?,
            let serverCreatedAtMs = row[Schema.TeamEventsMirror.serverCreatedAtMs] as Int64?,
            let eventTsMs = row[Schema.TeamEventsMirror.eventTsMs] as Int64?,
            let receivedAtMs = row[Schema.TeamEventsMirror.receivedAtMs] as Int64?
        else { return nil }

        return TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkeyHex,
            source: source,
            kind: kind,
            plaintextPayloadJSON: payloadJSON,
            serverCreatedAtMs: serverCreatedAtMs,
            eventTsMs: eventTsMs,
            receivedAtMs: receivedAtMs
        )
    }
}
