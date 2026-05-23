//
//  TeamFeedQueryService.swift
//  LeafCore
//
//  Track 5 / S7 C.3 — Pure actor that executes the UNION merge query across
//  messages_mirror (DMs) + team_events_mirror (broadcast events), applying
//  FeedFilter dispatch and pagination cursor.
//
//  Design notes (per spec §7.1):
//  • All SQL values are passed as GRDB StatementArguments — no string interpolation
//    of user-derived values (workspace IDs, pubkeys, timestamps).
//  • The IN clause for source_kind uses positional placeholders (one per item)
//    built from the resolved source_kind list — avoids CSV injection.
//  • The query service NEVER produces .grouped FeedItems. Grouping is a
//    presentation-layer transform in TeamFeedReader.applyGrouping (C.5).
//  • Rows that fail to decode are logged and skipped (don't poison feed render).
//

import Foundation
import GRDB
import os

/// Pure actor: executes the UNION merge query for the Team feed and returns
/// `[FeedItem]` sorted by `server_created_at_ms DESC`.
public actor TeamFeedQueryService {

    private let database: Database
    private let logger = Logger(subsystem: "tech.gundem.leaf", category: "team-feed-query")

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Public API

    /// Fetch a page of feed items for the given workspace.
    ///
    /// - Parameters:
    ///   - workspaceID:     Target workspace. Rows from other workspaces excluded.
    ///   - filters:         Multi-select filter set per spec §4.5. `.all` = all DMs + all events.
    ///   - limit:           Maximum rows returned (pagination page size).
    ///   - before:          If non-nil, only rows with `server_created_at_ms < before`
    ///                      are returned (strict less-than, avoids boundary duplicates).
    ///   - selfPubkeyHex:   Own pubkey hex — used to scope `.openTasks` filter to
    ///                      tasks where `recipient_pubkey_hex = me`.
    /// - Returns:           FeedItems sorted by `server_created_at_ms DESC`.
    public func fetch(
        workspaceID: String,
        filters: Set<FeedFilter>,
        limit: Int,
        before: Int64?,
        selfPubkeyHex: String
    ) async throws -> [FeedItem] {
        let resolved = FilterResolution(filters: filters, selfPubkeyHex: selfPubkeyHex)
        return try database.readSQL { db in
            try Self.runQuery(
                db: db,
                workspaceID: workspaceID,
                resolved: resolved,
                limit: limit,
                before: before
            )
        }
    }

    // MARK: - Internal query execution

    private static func runQuery(
        db: GRDB.Database,
        workspaceID: String,
        resolved: FilterResolution,
        limit: Int,
        before: Int64?
    ) throws -> [FeedItem] {

        // Build the dynamic IN clause for source_kinds.
        // We use one positional placeholder per element to avoid CSV injection.
        let sourceKinds = resolved.sourceKinds
        let includeEvents = !sourceKinds.isEmpty
        let includeDMs = resolved.includeDMs
        let openTasksOnly = resolved.openTasksOnly
        let selfPubkeyHex = resolved.selfPubkeyHex

        // If nothing is included, short-circuit.
        if !includeDMs && !includeEvents {
            return []
        }

        // Build the CTE branches.
        // DM branch — conditionally included via a WHERE clause.
        // We use a dummy "1=0" when DMs are excluded to avoid UNION shape mismatch.
        let dmBranch = """
            SELECT
                'dm'                                     AS source,
                \(Schema.MessagesMirror.messageID)       AS id,
                \(Schema.MessagesMirror.senderPubkeyHex) AS sender_pubkey_hex,
                \(Schema.MessagesMirror.kind)            AS dm_kind,
                \(Schema.MessagesMirror.body)            AS dm_body,
                \(Schema.MessagesMirror.sentAtMs)        AS sent_at_ms,
                \(Schema.MessagesMirror.serverCreatedAtMs) AS server_created_at_ms,
                \(Schema.MessagesMirror.direction)       AS direction,
                \(Schema.MessagesMirror.recipientPubkeyHex) AS recipient_pubkey_hex,
                \(Schema.MessagesMirror.readAtMs)        AS read_at_ms,
                \(Schema.MessagesMirror.doneAtMs)        AS done_at_ms,
                \(Schema.MessagesMirror.workspaceID)     AS workspace_id,
                \(Schema.MessagesMirror.senderMemberID)  AS sender_member_id,
                \(Schema.MessagesMirror.senderDisplayName) AS sender_display_name,
                \(Schema.MessagesMirror.attachmentKind)  AS attachment_kind,
                \(Schema.MessagesMirror.attachmentExternalRef) AS attachment_external_ref,
                \(Schema.MessagesMirror.replyTo)         AS reply_to,
                \(Schema.MessagesMirror.doneByPubkeyHex) AS done_by_pubkey_hex,
                \(Schema.MessagesMirror.lastSyncedAtMs)  AS last_synced_at_ms,
                NULL                                     AS source_kind,
                NULL                                     AS event_kind,
                NULL                                     AS plaintext_payload_json,
                NULL                                     AS event_ts_ms,
                NULL                                     AS received_at_ms
            FROM \(Schema.MessagesMirror.tableName)
            WHERE \(Schema.MessagesMirror.workspaceID) = ?
              AND \(includeDMs ? "1=1" : "1=0")
              AND \(openTasksOnly ? "(\(Schema.MessagesMirror.kind) = 'task' AND \(Schema.MessagesMirror.doneAtMs) IS NULL AND \(Schema.MessagesMirror.recipientPubkeyHex) = ?)" : "1=1")
            """

        // Event branch
        let placeholders = sourceKinds.isEmpty ? "" : "(" + sourceKinds.map { _ in "?" }.joined(separator: ", ") + ")"
        let evtBranch = """
            SELECT
                'evt'                                       AS source,
                \(Schema.TeamEventsMirror.eventID)          AS id,
                \(Schema.TeamEventsMirror.senderPubkeyHex)  AS sender_pubkey_hex,
                NULL                                        AS dm_kind,
                NULL                                        AS dm_body,
                NULL                                        AS sent_at_ms,
                \(Schema.TeamEventsMirror.serverCreatedAtMs) AS server_created_at_ms,
                NULL                                        AS direction,
                NULL                                        AS recipient_pubkey_hex,
                NULL                                        AS read_at_ms,
                NULL                                        AS done_at_ms,
                \(Schema.TeamEventsMirror.workspaceID)      AS workspace_id,
                NULL                                        AS sender_member_id,
                NULL                                        AS sender_display_name,
                NULL                                        AS attachment_kind,
                NULL                                        AS attachment_external_ref,
                NULL                                        AS reply_to,
                NULL                                        AS done_by_pubkey_hex,
                NULL                                        AS last_synced_at_ms,
                \(Schema.TeamEventsMirror.sourceKind)       AS source_kind,
                \(Schema.TeamEventsMirror.kind)             AS event_kind,
                \(Schema.TeamEventsMirror.plaintextPayloadJSON) AS plaintext_payload_json,
                \(Schema.TeamEventsMirror.eventTsMs)        AS event_ts_ms,
                \(Schema.TeamEventsMirror.receivedAtMs)     AS received_at_ms
            FROM \(Schema.TeamEventsMirror.tableName)
            WHERE \(Schema.TeamEventsMirror.workspaceID) = ?
              AND \(includeEvents ? "\(Schema.TeamEventsMirror.sourceKind) IN \(placeholders)" : "1=0")
            """

        // Outer SELECT with optional cursor
        let beforeClause = before != nil ? "WHERE server_created_at_ms < ?" : ""
        let sql = """
            WITH combined AS (
                \(dmBranch)
                UNION ALL
                \(evtBranch)
            )
            SELECT * FROM combined
            \(beforeClause)
            ORDER BY server_created_at_ms DESC
            LIMIT ?
            """

        // Build arguments in the correct order matching the SQL placeholders.
        var args: [DatabaseValueConvertible?] = []

        // DM branch args: workspaceID + (optionally selfPubkeyHex for openTasks)
        args.append(workspaceID)
        if openTasksOnly {
            args.append(selfPubkeyHex)
        }

        // Event branch args: workspaceID + source_kind values
        args.append(workspaceID)
        for kind in sourceKinds {
            args.append(kind)
        }

        // Outer args: before cursor + limit
        if let before = before {
            args.append(before)
        }
        args.append(limit)

        // Flatten to StatementArguments — GRDB accepts [DatabaseValueConvertible?]
        // We can't use spread because the count is dynamic; use the sequence init.
        let stmtArgs = StatementArguments(args)
        let rows = try Row.fetchAll(db, sql: sql, arguments: stmtArgs)
        return rows.compactMap { Self.mapRow($0) }
    }

    // MARK: - Row → FeedItem decoding

    private static func mapRow(_ row: Row) -> FeedItem? {
        guard let source = row["source"] as String? else { return nil }
        switch source {
        case "dm":
            return mapDMRow(row).map { .directMessage($0) }
        case "evt":
            // M-IX — precompute the row's action text once here (the single
            // DB→FeedItem mapping site) so the view never parses payload JSON
            // during render.
            return mapEventRow(row).map { .teamEvent(RenderedTeamEvent(row: $0)) }
        default:
            return nil
        }
    }

    private static func mapDMRow(_ row: Row) -> DirectMessageMirrorRow? {
        guard
            let messageID   = row["id"] as String?,
            let workspaceID = row["workspace_id"] as String?,
            let senderPubkeyHex = row["sender_pubkey_hex"] as String?,
            let senderMemberID  = row["sender_member_id"] as String?,
            let senderDisplayName = row["sender_display_name"] as String?,
            let recipientPubkeyHex = row["recipient_pubkey_hex"] as String?,
            let kindRaw     = row["dm_kind"] as String?,
            let kind        = DirectMessageKind(rawValue: kindRaw),
            let body        = row["dm_body"] as String?,
            let sentAtMs    = row["sent_at_ms"] as Int64?,
            let serverCreatedAtMs = row["server_created_at_ms"] as Int64?,
            let directionRaw = row["direction"] as String?,
            let direction   = DirectMessageMirrorRow.Direction(rawValue: directionRaw),
            let lastSyncedAtMs = row["last_synced_at_ms"] as Int64?
        else { return nil }

        let attachmentKind = row["attachment_kind"] as String?
        let attachmentRef  = row["attachment_external_ref"] as String?
        let attachment: DirectMessageAttachment? = attachmentKind.flatMap { k in
            attachmentRef.map { r in DirectMessageAttachment(kind: k, externalRef: r, displayLabel: nil) }
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
            replyTo: row["reply_to"] as String?,
            sentAtMs: sentAtMs,
            serverCreatedAtMs: serverCreatedAtMs,
            readAtMs: row["read_at_ms"] as Int64?,
            doneAtMs: row["done_at_ms"] as Int64?,
            doneByPubkeyHex: row["done_by_pubkey_hex"] as String?,
            direction: direction,
            lastSyncedAtMs: lastSyncedAtMs
        )
    }

    private static func mapEventRow(_ row: Row) -> TeamEventMirrorRow? {
        guard
            let eventID     = row["id"] as String?,
            let workspaceID = row["workspace_id"] as String?,
            let senderPubkeyHex = row["sender_pubkey_hex"] as String?,
            let sourceKindRaw   = row["source_kind"] as String?,
            let source      = ShareSource(rawValue: sourceKindRaw),
            let payloadJSON = row["plaintext_payload_json"] as String?,
            let serverCreatedAtMs = row["server_created_at_ms"] as Int64?,
            let eventTsMs   = row["event_ts_ms"] as Int64?,
            let receivedAtMs = row["received_at_ms"] as Int64?
        else { return nil }

        // event_kind may be any string (not an enum); fall back to "" if somehow NULL
        let eventKind = (row["event_kind"] as String?) ?? ""

        return TeamEventMirrorRow(
            eventID: eventID,
            workspaceID: workspaceID,
            senderPubkeyHex: senderPubkeyHex,
            source: source,
            kind: eventKind,
            plaintextPayloadJSON: payloadJSON,
            serverCreatedAtMs: serverCreatedAtMs,
            eventTsMs: eventTsMs,
            receivedAtMs: receivedAtMs
        )
    }
}

// MARK: - FilterResolution

/// Internal helper that resolves the raw `Set<FeedFilter>` into concrete query parameters.
///
/// Decoupled from `runQuery` so logic is testable via the public output properties.
private struct FilterResolution {

    let includeDMs: Bool
    let openTasksOnly: Bool
    let sourceKinds: [String]  // rawValues of ShareSource to include
    let selfPubkeyHex: String

    init(filters: Set<FeedFilter>, selfPubkeyHex: String) {
        self.selfPubkeyHex = selfPubkeyHex

        // .all → include everything
        if filters.contains(.all) {
            includeDMs = true
            openTasksOnly = false
            sourceKinds = ShareSource.allCases.map(\.rawValue)
            return
        }

        // DM inclusion: .directMessages OR .openTasks triggers DM fetch
        let wantsDMs = filters.contains(.directMessages)
        let wantsOpenTasks = filters.contains(.openTasks)
        includeDMs = wantsDMs || wantsOpenTasks

        // openTasksOnly: ONLY when .openTasks is selected WITHOUT .directMessages
        // i.e. the user wants "just my open tasks" not "all DMs"
        openTasksOnly = wantsOpenTasks && !wantsDMs

        // Resolve event source_kinds from filters
        var kinds: Set<String> = []
        for filter in filters {
            switch filter {
            case .all, .directMessages, .openTasks:
                break  // handled above
            case .decisions:
                kinds.insert(ShareSource.detectedDecisions.rawValue)
            case .blockers:
                kinds.insert(ShareSource.detectedBlockers.rawValue)
            case .shareSource(let src):
                kinds.insert(src.rawValue)
            }
        }
        sourceKinds = Array(kinds).sorted()  // deterministic order for placeholder binding
    }
}
