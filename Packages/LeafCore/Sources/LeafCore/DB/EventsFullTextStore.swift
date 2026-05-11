import Foundation
import GRDB
import os

/// Phase Track-1 D2 — FTS5 keyword index over event bodies.
///
/// `events_fts` is contentless (`content = ''`) so its UNINDEXED columns are
/// not retrievable post-MATCH. Sidecar `events_fts_meta(fts_rowid, event_id,
/// body_kind)` is the source of truth for retrieval; both rows are written
/// atomically by `indexEvent` inside the same transaction. `search()` joins
/// FTS rowid → meta → events.id (period filter via events.ts).
///
/// Static API. Caller wraps in `pool.write {}` / `pool.read {}` per existing
/// store convention (mirrors `PendingInvitesStore`). Body content lives in
/// `events.payload_json` (D1 capture) — D3 fetches excerpts from there.
public enum EventsFullTextStore {

    private static let log = Logger(subsystem: "tech.gundem.leaf.core", category: "fts")

    /// Lightweight inline shapes for decoding D1 fan-out payloads. Forward-compat:
    /// extra JSON keys are ignored.
    private struct BodyOnly: Decodable { let body: String }
    private struct TextOnly: Decodable { let text: String }

    /// Body extraction + FTS5 row insertion for a single event. Called inside the
    /// same `pool.write {}` transaction as the event insert (see
    /// `Database.writeEventAndDerived` in commit 5). No-op (no rows inserted)
    /// for events without body-bearing payload keys.
    ///
    /// Decode failures on JSON-blob keys are logged and skipped — the event row
    /// stays inserted; that JSON key contributes 0 FTS rows.
    public static func indexEvent(
        eventID: Int64,
        signalType: String,
        bundleID: String?,
        payload: [String: String],
        in db: GRDB.Database
    ) throws {
        let eventKind = payload["event_kind"] ?? ""

        // 1) Top-level body → 1 row, body_kind dispatched by event_kind.
        if let raw = payload[Schema.EventPayloadKeys.body],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let bodyKind = topLevelBodyKind(forEventKind: eventKind) {
                try insertRow(eventID: eventID, bodyKind: bodyKind, body: raw, in: db)
            }
        }

        // 2) Linear comments fan-out.
        if let raw = payload[Schema.EventPayloadKeys.commentBodiesJson] {
            for body in decodeStringArray(raw, type: BodyOnly.self, key: \BodyOnly.body) {
                try insertRow(eventID: eventID, bodyKind: Schema.BodyKinds.linearComment, body: body, in: db)
            }
        }

        // 3) Slack thread replies fan-out.
        if let raw = payload[Schema.EventPayloadKeys.threadRepliesJson] {
            for text in decodeStringArray(raw, type: TextOnly.self, key: \TextOnly.text) {
                try insertRow(eventID: eventID, bodyKind: Schema.BodyKinds.slackThreadReply, body: text, in: db)
            }
        }

        // 4) Slack messages aggregate fan-out.
        if let raw = payload[Schema.EventPayloadKeys.messagesJson] {
            for text in decodeStringArray(raw, type: TextOnly.self, key: \TextOnly.text) {
                try insertRow(eventID: eventID, bodyKind: Schema.BodyKinds.slackMsg, body: text, in: db)
            }
        }
    }

    /// FTS5 keyword search returning DISTINCT event IDs ranked by BM25,
    /// filtered by inclusive ts range. Limit applied after dedup.
    /// Caller passes pre-validated query string — no input sanitization here
    /// (D3 `leaf_query_activity` will own that).
    public static func search(
        query: String,
        period: ClosedRange<Int64>,
        limit: Int = 100,
        in db: GRDB.Database
    ) throws -> [Int64] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT events_fts_meta.event_id AS eid, MIN(rank) AS best_rank
                FROM events_fts
                JOIN events_fts_meta ON events_fts_meta.fts_rowid = events_fts.rowid
                JOIN events ON events.id = events_fts_meta.event_id
                WHERE events_fts MATCH ?
                  AND events.ts BETWEEN ? AND ?
                GROUP BY events_fts_meta.event_id
                ORDER BY best_rank
                LIMIT ?
                """,
            arguments: [query, period.lowerBound, period.upperBound, limit]
        )
        return rows.compactMap { $0["eid"] as Int64? }
    }

    // MARK: - Private

    private static func topLevelBodyKind(forEventKind eventKind: String) -> String? {
        // Track-1 D2 carry-over fix: LinearCollector emits "issue_updated"
        // (без "linear_" префикса); старая dispatch строка пропускала Linear
        // descriptions из FTS. Track-3 D1 фиксит, добавляет notification_title.
        if eventKind == "issue_updated" { return Schema.BodyKinds.linearDesc }
        if eventKind == "linear_notification_received" { return Schema.BodyKinds.linearNotificationTitle }
        if eventKind == "commit_pushed" { return Schema.BodyKinds.commitMsg }
        if eventKind == "gh_issue_comment_authored" { return Schema.BodyKinds.ghIssueComment }
        if eventKind == "gh_pr_review_comment_authored" { return Schema.BodyKinds.ghPRReviewComment }
        if eventKind == "slack_thread_reply_aggregate" { return Schema.BodyKinds.slackThreadParent }
        if eventKind.hasPrefix("gh_pr_") { return Schema.BodyKinds.ghPR }
        return nil
    }

    /// Inserts one FTS5 row + sidecar meta row atomically within the active
    /// transaction. Empty / whitespace-only bodies skipped.
    private static func insertRow(eventID: Int64, bodyKind: String, body: String, in db: GRDB.Database) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try db.execute(
            sql: "INSERT INTO events_fts (event_id, body_kind, body) VALUES (?, ?, ?)",
            arguments: [eventID, bodyKind, body]
        )
        let ftsRowID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO events_fts_meta (fts_rowid, event_id, body_kind) VALUES (?, ?, ?)",
            arguments: [ftsRowID, eventID, bodyKind]
        )
    }

    /// Decodes a JSON array of `[{ <key>: String }]` records into `[String]`,
    /// dropping empty entries. On JSON failure logs + returns [] (graceful).
    private static func decodeStringArray<T: Decodable>(
        _ raw: String,
        type: T.Type,
        key: KeyPath<T, String>
    ) -> [String] {
        guard let data = raw.data(using: .utf8) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([T].self, from: data)
            return decoded.map { $0[keyPath: key] }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            log.error("EventsFullTextStore JSON decode failure: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
