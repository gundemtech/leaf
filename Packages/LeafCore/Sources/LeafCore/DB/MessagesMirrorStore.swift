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
                    \(Schema.MessagesMirror.contextSnapshotJSON),
                    \(Schema.MessagesMirror.replyTo),
                    \(Schema.MessagesMirror.sentAtMs),
                    \(Schema.MessagesMirror.serverCreatedAtMs),
                    \(Schema.MessagesMirror.readAtMs),
                    \(Schema.MessagesMirror.doneAtMs),
                    \(Schema.MessagesMirror.doneByPubkeyHex),
                    \(Schema.MessagesMirror.direction),
                    \(Schema.MessagesMirror.lastSyncedAtMs)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                Self.encodeSnapshot(row.contextSnapshot),
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

    /// Team chats — both directions of the 1:1 conversation with `peer`:
    /// inbound rows the peer sent (sender = peer) + outbound rows we sent
    /// them (recipient = peer). Returns the LATEST `limit` rows in
    /// ASCENDING order (chat renders oldest → newest).
    public static func readConversation(
        workspaceID: String,
        peerPubkeyHex: String,
        limit: Int = 200,
        in db: GRDB.Database
    ) throws -> [DirectMessageMirrorRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM (
                  \(selectAllSQL)
                  WHERE \(Schema.MessagesMirror.workspaceID) = ?
                    AND (
                      (\(Schema.MessagesMirror.direction) = ?
                        AND \(Schema.MessagesMirror.senderPubkeyHex) = ?)
                      OR
                      (\(Schema.MessagesMirror.direction) = ?
                        AND \(Schema.MessagesMirror.recipientPubkeyHex) = ?)
                    )
                  ORDER BY \(Schema.MessagesMirror.serverCreatedAtMs) DESC
                  LIMIT ?
                )
                ORDER BY \(Schema.MessagesMirror.serverCreatedAtMs) ASC
                """,
            arguments: [
                workspaceID,
                Schema.MessagesMirror.directionInbound, peerPubkeyHex,
                Schema.MessagesMirror.directionOutbound, peerPubkeyHex,
                limit,
            ]
        )
        return rows.compactMap(Self.mapRow)
    }

    /// Team chats — one rollup row per conversation counterpart: the latest
    /// message (bare columns ride SQLite's single-MAX() row guarantee) +
    /// inbound-unread count. Peer identity = sender for inbound rows,
    /// recipient for outbound.
    public static func conversationSummaries(
        workspaceID: String,
        in db: GRDB.Database
    ) throws -> [ChatPeerSummary] {
        let peerExpr = """
            CASE WHEN \(Schema.MessagesMirror.direction) = '\(Schema.MessagesMirror.directionOutbound)'
                 THEN \(Schema.MessagesMirror.recipientPubkeyHex)
                 ELSE \(Schema.MessagesMirror.senderPubkeyHex) END
            """
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                  \(peerExpr) AS peer,
                  \(Schema.MessagesMirror.body) AS last_body,
                  \(Schema.MessagesMirror.kind) AS last_kind,
                  \(Schema.MessagesMirror.direction) AS last_direction,
                  MAX(\(Schema.MessagesMirror.serverCreatedAtMs)) AS last_ms,
                  SUM(
                    CASE WHEN \(Schema.MessagesMirror.direction) = ?
                          AND \(Schema.MessagesMirror.readAtMs) IS NULL
                         THEN 1 ELSE 0 END
                  ) AS unread
                FROM \(Schema.MessagesMirror.tableName)
                WHERE \(Schema.MessagesMirror.workspaceID) = ?
                GROUP BY peer
                """,
            arguments: [Schema.MessagesMirror.directionInbound, workspaceID]
        )
        return rows.compactMap { row in
            guard
                let peer: String = row["peer"],
                let body: String = row["last_body"],
                let kindRaw: String = row["last_kind"],
                let kind = DirectMessageKind(rawValue: kindRaw),
                let lastMs: Int64 = row["last_ms"],
                let directionRaw: String = row["last_direction"],
                let direction = DirectMessageMirrorRow.Direction(rawValue: directionRaw)
            else { return nil }
            return ChatPeerSummary(
                peerPubkeyHex: peer,
                lastBody: body,
                lastKind: kind,
                lastAtMs: lastMs,
                lastIsOutbound: direction == .outbound,
                unreadCount: row["unread"] ?? 0
            )
        }
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

    /// Per-workspace count of unread inbound DMs.
    /// Single SQL aggregate — uses `idx_messages_mirror_unread` partial index.
    /// Returns an empty dict when no unread messages exist.
    ///
    /// S7 Stage 6 fix B-I3 — direction enum bound via `?` argument instead of
    /// inline string interpolation. The value is a compile-time constant
    /// today, but bind-via-argument is the uniform pattern across this file
    /// (e.g., `readUnreadInbound` on the line above) and defends against a
    /// hypothetical future where the constant becomes user-derived or
    /// contains a quote that breaks the literal SQL.
    public static func unreadInboundCountByWorkspace(in db: GRDB.Database) throws -> [String: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(Schema.MessagesMirror.workspaceID), COUNT(*) AS cnt
            FROM \(Schema.MessagesMirror.tableName)
            WHERE \(Schema.MessagesMirror.direction) = ?
              AND \(Schema.MessagesMirror.readAtMs) IS NULL
            GROUP BY \(Schema.MessagesMirror.workspaceID)
            """, arguments: [Schema.MessagesMirror.directionInbound])
        var result: [String: Int] = [:]
        for row in rows {
            if let wid: String = row[Schema.MessagesMirror.workspaceID],
               let cnt: Int = row["cnt"] {
                result[wid] = cnt
            }
        }
        return result
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

    // MARK: - Track 5 / S8 T6 — pending_mark_done retry queue (M026 column)

    /// SELECT message_id WHERE `pending_mark_done = 1`.
    ///
    /// Drives `PendingMarkDoneRetryService.tick()` — daily-tick background
    /// retry for rows where the optimistic local UPDATE landed but the
    /// server PATCH (via `SupabaseClient.markDone`) failed (network /
    /// transient 5xx). Uses the `idx_messages_mirror_pending_mark_done`
    /// partial index for O(pending) seek (M026 / T1).
    public static func fetchPendingMarkDoneIDs(in db: GRDB.Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT \(Schema.MessagesMirror.messageID)
                FROM \(Schema.MessagesMirror.tableName)
                WHERE \(Schema.MessagesMirror.pendingMarkDone) = 1
                """
        )
    }

    /// UPDATE `pending_mark_done` flag (0 = cleared, 1 = needs retry).
    /// `lastSyncedAtMs` is NOT touched — the flag itself does not represent
    /// a server-confirmed state, so it would mis-signal sync recency.
    public static func setPendingMarkDone(
        messageID: String,
        pending: Bool,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE \(Schema.MessagesMirror.tableName)
                SET \(Schema.MessagesMirror.pendingMarkDone) = ?
                WHERE \(Schema.MessagesMirror.messageID) = ?
                """,
            arguments: [pending ? 1 : 0, messageID]
        )
    }

    /// Optimistic-local `markDone` — UPDATE `done_at_ms` + `done_by_pubkey_hex`
    /// AND clear `pending_mark_done` flag in one statement. Distinct from
    /// `markDone(messageID:atMs:doneByPubkeyHex:)` (which is used by the
    /// post-server-PATCH path) — this variant is for the APNs `dm.markDone`
    /// flow where we set local state first and then attempt the server PATCH.
    /// On a successful server PATCH, callers can just leave `pending_mark_done`
    /// at the 0 default; on failure they call `setPendingMarkDone(pending: true)`
    /// to flag the row for the retry queue.
    public static func markDoneLocalOptimistic(
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
                    \(Schema.MessagesMirror.lastSyncedAtMs) = ?,
                    \(Schema.MessagesMirror.pendingMarkDone) = 0
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
               \(Schema.MessagesMirror.contextSnapshotJSON),
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

    // Track C — JSON helpers for the context snapshot column. Encode failures
    // map to NULL (the DM body is the source of truth; the card is sugar).
    static func encodeSnapshot(_ snapshot: HandoffContextSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(snapshot)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeSnapshot(_ json: String) -> HandoffContextSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HandoffContextSnapshot.self, from: data)
    }

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
        // Track C — tolerant: snapshot rot maps to nil, never drops the row.
        let contextSnapshot = (row[Schema.MessagesMirror.contextSnapshotJSON] as String?)
            .flatMap { Self.decodeSnapshot($0) }
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
            contextSnapshot: contextSnapshot,
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
