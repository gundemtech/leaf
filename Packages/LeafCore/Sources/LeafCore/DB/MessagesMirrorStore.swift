import Foundation
import GRDB

/// Phase Track-5 S4 — CRUD over `messages_mirror`. Static methods receive raw
/// `GRDB.Database` handle; caller wraps in `pool.write`/`pool.read`. Mirrors
/// `PendingInvitesStore` style.
public struct MessagesMirrorStore: Sendable {

    /// UPSERT row. `INSERT ... ON CONFLICT DO UPDATE` — idempotent.
    /// Inbox tick may receive the same Supabase row twice (cold-start +
    /// fresh poll); UPSERT keeps mirror consistent. `direction` is preserved
    /// from the FIRST insert path (i.e., once a row is outbound, second-write
    /// from another path treats it as outbound).
    public static func upsert(_ row: DirectMessageMirrorRow, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                INSERT INTO \(Schema.MessagesMirror.tableName) (
                    \(Schema.MessagesMirror.messageID),
                    \(Schema.MessagesMirror.workspaceID),
                    \(Schema.MessagesMirror.senderPubkeyHex),
                    \(Schema.MessagesMirror.senderMemberID),
                    \(Schema.MessagesMirror.senderDisplayName),
                    \(Schema.MessagesMirror.recipientPubkeyHex),
                    \(Schema.MessagesMirror.kind),
                    \(Schema.MessagesMirror.body),
                    \(Schema.MessagesMirror.attachmentKind),
                    \(Schema.MessagesMirror.attachmentExternalRef),
                    \(Schema.MessagesMirror.replyTo),
                    \(Schema.MessagesMirror.sentAtMs),
                    \(Schema.MessagesMirror.serverCreatedAtMs),
                    \(Schema.MessagesMirror.readAtMs),
                    \(Schema.MessagesMirror.doneAtMs),
                    \(Schema.MessagesMirror.doneByPubkeyHex),
                    \(Schema.MessagesMirror.direction),
                    \(Schema.MessagesMirror.lastSyncedAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(\(Schema.MessagesMirror.messageID)) DO UPDATE SET
                    \(Schema.MessagesMirror.readAtMs)        = COALESCE(excluded.\(Schema.MessagesMirror.readAtMs), \(Schema.MessagesMirror.readAtMs)),
                    \(Schema.MessagesMirror.doneAtMs)        = COALESCE(excluded.\(Schema.MessagesMirror.doneAtMs), \(Schema.MessagesMirror.doneAtMs)),
                    \(Schema.MessagesMirror.doneByPubkeyHex) = COALESCE(excluded.\(Schema.MessagesMirror.doneByPubkeyHex), \(Schema.MessagesMirror.doneByPubkeyHex)),
                    \(Schema.MessagesMirror.lastSyncedAtMs)  = excluded.\(Schema.MessagesMirror.lastSyncedAtMs)
                """,
            arguments: [
                row.messageID,
                row.workspaceID,
                row.senderPubkeyHex,
                row.senderMemberID,
                row.senderDisplayName,
                row.recipientPubkeyHex,
                row.kind.rawValue,
                row.body,
                row.attachment?.kind,
                row.attachment?.externalRef,
                row.replyTo,
                row.sentAtMs,
                row.serverCreatedAtMs,
                row.readAtMs,
                row.doneAtMs,
                row.doneByPubkeyHex,
                row.direction.rawValue,
                row.lastSyncedAtMs
            ]
        )
    }

    /// SELECT single by message_id PK. nil when missing.
    public static func read(messageID: String, in db: GRDB.Database) throws -> DirectMessageMirrorRow? {
        let row = try Row.fetchOne(
            db,
            sql: """
                \(selectAllSQL)
                WHERE \(Schema.MessagesMirror.messageID) = ?
                LIMIT 1
                """,
            arguments: [messageID]
        )
        return row.flatMap(Self.mapRow)
    }

    /// SELECT all rows for a workspace, ordered server_created_at_ms DESC.
    /// Optionally bounded by `limit`.
    public static func readRecent(
        workspaceID: String,
        limit: Int = 100,
        in db: GRDB.Database
    ) throws -> [DirectMessageMirrorRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                \(selectAllSQL)
                WHERE \(Schema.MessagesMirror.workspaceID) = ?
                ORDER BY \(Schema.MessagesMirror.serverCreatedAtMs) DESC
                LIMIT ?
                """,
            arguments: [workspaceID, limit]
        )
        return rows.compactMap(Self.mapRow)
    }

    /// SELECT unread inbound rows for a workspace + recipient. Used by Inbox UI badge.
    public static func readUnreadInbound(
        workspaceID: String,
        recipientPubkeyHex: String,
        in db: GRDB.Database
    ) throws -> [DirectMessageMirrorRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                \(selectAllSQL)
                WHERE \(Schema.MessagesMirror.workspaceID) = ?
                  AND \(Schema.MessagesMirror.recipientPubkeyHex) = ?
                  AND \(Schema.MessagesMirror.readAtMs) IS NULL
                  AND \(Schema.MessagesMirror.direction) = ?
                ORDER BY \(Schema.MessagesMirror.serverCreatedAtMs) DESC
                """,
            arguments: [workspaceID, recipientPubkeyHex, Schema.MessagesMirror.directionInbound]
        )
        return rows.compactMap(Self.mapRow)
    }

    /// MAX(server_created_at_ms) for incremental sync cursor. nil → cold bootstrap.
    public static func maxServerCreatedAtMs(
        workspaceID: String,
        direction: DirectMessageMirrorRow.Direction,
        in db: GRDB.Database
    ) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: """
                SELECT MAX(\(Schema.MessagesMirror.serverCreatedAtMs))
                FROM \(Schema.MessagesMirror.tableName)
                WHERE \(Schema.MessagesMirror.workspaceID) = ?
                  AND \(Schema.MessagesMirror.direction) = ?
                """,
            arguments: [workspaceID, direction.rawValue]
        )
    }

    /// UPDATE read_at_ms.
    public static func markRead(messageID: String, atMs: Int64, in db: GRDB.Database) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.MessagesMirror.tableName)
                SET \(Schema.MessagesMirror.readAtMs) = ?,
                    \(Schema.MessagesMirror.lastSyncedAtMs) = ?
                WHERE \(Schema.MessagesMirror.messageID) = ?
                """,
            arguments: [atMs, atMs, messageID]
        )
    }

    /// UPDATE done_at_ms + done_by_pubkey_hex.
    public static func markDone(
        messageID: String,
        atMs: Int64,
        doneByPubkeyHex: String,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.MessagesMirror.tableName)
                SET \(Schema.MessagesMirror.doneAtMs) = ?,
                    \(Schema.MessagesMirror.doneByPubkeyHex) = ?,
                    \(Schema.MessagesMirror.lastSyncedAtMs) = ?
                WHERE \(Schema.MessagesMirror.messageID) = ?
                """,
            arguments: [atMs, doneByPubkeyHex, atMs, messageID]
        )
    }

    // MARK: - Private

    private static let selectAllSQL = """
        SELECT \(Schema.MessagesMirror.messageID),
               \(Schema.MessagesMirror.workspaceID),
               \(Schema.MessagesMirror.senderPubkeyHex),
               \(Schema.MessagesMirror.senderMemberID),
               \(Schema.MessagesMirror.senderDisplayName),
               \(Schema.MessagesMirror.recipientPubkeyHex),
               \(Schema.MessagesMirror.kind),
               \(Schema.MessagesMirror.body),
               \(Schema.MessagesMirror.attachmentKind),
               \(Schema.MessagesMirror.attachmentExternalRef),
               \(Schema.MessagesMirror.replyTo),
               \(Schema.MessagesMirror.sentAtMs),
               \(Schema.MessagesMirror.serverCreatedAtMs),
               \(Schema.MessagesMirror.readAtMs),
               \(Schema.MessagesMirror.doneAtMs),
               \(Schema.MessagesMirror.doneByPubkeyHex),
               \(Schema.MessagesMirror.direction),
               \(Schema.MessagesMirror.lastSyncedAtMs)
        FROM \(Schema.MessagesMirror.tableName)
        """

    private static func mapRow(_ row: Row) -> DirectMessageMirrorRow? {
        guard
            let messageID = row[Schema.MessagesMirror.messageID] as String?,
            let workspaceID = row[Schema.MessagesMirror.workspaceID] as String?,
            let senderPubkeyHex = row[Schema.MessagesMirror.senderPubkeyHex] as String?,
            let senderMemberID = row[Schema.MessagesMirror.senderMemberID] as String?,
            let senderDisplayName = row[Schema.MessagesMirror.senderDisplayName] as String?,
            let recipientPubkeyHex = row[Schema.MessagesMirror.recipientPubkeyHex] as String?,
            let kindRaw = row[Schema.MessagesMirror.kind] as String?,
            let kind = DirectMessageKind(rawValue: kindRaw),
            let body = row[Schema.MessagesMirror.body] as String?,
            let sentAtMs = row[Schema.MessagesMirror.sentAtMs] as Int64?,
            let serverCreatedAtMs = row[Schema.MessagesMirror.serverCreatedAtMs] as Int64?,
            let directionRaw = row[Schema.MessagesMirror.direction] as String?,
            let direction = DirectMessageMirrorRow.Direction(rawValue: directionRaw),
            let lastSyncedAtMs = row[Schema.MessagesMirror.lastSyncedAtMs] as Int64?
        else { return nil }

        let attachmentKind = row[Schema.MessagesMirror.attachmentKind] as String?
        let attachmentExternalRef = row[Schema.MessagesMirror.attachmentExternalRef] as String?
        let attachment: DirectMessageAttachment?
        if let k = attachmentKind, let r = attachmentExternalRef {
            attachment = DirectMessageAttachment(kind: k, externalRef: r, displayLabel: nil)
        } else {
            attachment = nil
        }

        return DirectMessageMirrorRow(
            messageID: messageID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkeyHex,
            senderMemberID: senderMemberID,
            senderDisplayName: senderDisplayName,
            recipientPubkeyHex: recipientPubkeyHex,
            kind: kind,
            body: body,
            attachment: attachment,
            replyTo: row[Schema.MessagesMirror.replyTo] as String?,
            sentAtMs: sentAtMs,
            serverCreatedAtMs: serverCreatedAtMs,
            readAtMs: row[Schema.MessagesMirror.readAtMs] as Int64?,
            doneAtMs: row[Schema.MessagesMirror.doneAtMs] as Int64?,
            doneByPubkeyHex: row[Schema.MessagesMirror.doneByPubkeyHex] as String?,
            direction: direction,
            lastSyncedAtMs: lastSyncedAtMs
        )
    }
}
