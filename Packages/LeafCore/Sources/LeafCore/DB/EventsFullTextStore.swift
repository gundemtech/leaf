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
        // Track-4 S4: dispatcher returns (payloadKey, bodyKind) — Track-1/3 routes
        // resolve to canonical `body` field, Track-4 S2/S3 routes return non-canonical
        // user-authored title/filename keys (`note_title`, `meeting_topic`, `filename`).
        if let (payloadKey, bodyKind) = topLevelBodyKind(forEventKind: eventKind),
           let raw = payload[payloadKey],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try insertRow(eventID: eventID, bodyKind: bodyKind, body: raw, in: db)
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

    /// Returns `(payloadKey, bodyKind)` for event_kinds that carry searchable
    /// content in payload. `payloadKey` is the payload field name to read body
    /// text from (canonical `body` for Track-1/3 where collectors emit a body
    /// field; non-canonical fields for Track-4 S2/S3 user-authored title/filename
    /// payloads — see ADR-010 commit-message precedent).
    private static func topLevelBodyKind(forEventKind eventKind: String) -> (payloadKey: String, bodyKind: String)? {
        let canonical = Schema.EventPayloadKeys.body

        // Track-1 D2 carry-over fix: LinearCollector emits "issue_updated"
        // (without a "linear_" prefix); the old dispatch line skipped Linear
        // descriptions from FTS. Track-3 D1 fixes this, adds notification_title.
        if eventKind == "issue_updated" { return (canonical, Schema.BodyKinds.linearDesc) }
        if eventKind == "linear_notification_received" { return (canonical, Schema.BodyKinds.linearNotificationTitle) }
        if eventKind == GitHubEventKindKey.commitPushed.rawValue { return (canonical, Schema.BodyKinds.commitMsg) }
        // Track A1 — local git log collector. Self-authored commit subject+body
        // (ADR-010 commit-message precedent); same body_kind as the GitHub feed
        // variant so D3 query paths treat both sources uniformly.
        if eventKind == "git_commit_authored" { return (canonical, Schema.BodyKinds.commitMsg) }
        if eventKind == GitHubEventKindKey.issueCommentAuthored.rawValue { return (canonical, Schema.BodyKinds.ghIssueComment) }
        if eventKind == GitHubEventKindKey.prReviewCommentAuthored.rawValue { return (canonical, Schema.BodyKinds.ghPRReviewComment) }
        if eventKind == "slack_thread_reply_aggregate" { return (canonical, Schema.BodyKinds.slackThreadParent) }
        // Track-3 D2: explicit gh_* cases instead of bare hasPrefix("gh_pr_")
        // catch-all (which would spuriously match gh_pr_review_thread_resolved
        // and gh_pr_awaiting_review_count whose body-bearing is nil).
        if eventKind == GitHubEventKindKey.prOpened.rawValue
            || eventKind == GitHubEventKindKey.prMerged.rawValue
            || eventKind == GitHubEventKindKey.prClosed.rawValue {
            return (canonical, Schema.BodyKinds.ghPR)
        }
        if eventKind == GitHubEventKindKey.issueOpened.rawValue
            || eventKind == GitHubEventKindKey.issueClosed.rawValue {
            return (canonical, Schema.BodyKinds.ghIssueComment)  // issue body indexed under same kind as issue comments
        }
        // Track-3 D2 §4.3 — gist description / release body / deployment description
        // body-kind dispatch. Body field, when present in payload, is routed to the
        // dedicated body_kind so D3 query path can filter.
        if eventKind == GitHubEventKindKey.gistCreated.rawValue
            || eventKind == GitHubEventKindKey.gistUpdated.rawValue {
            return (canonical, Schema.BodyKinds.ghGistDescription)
        }
        if eventKind == GitHubEventKindKey.releasePublished.rawValue {
            return (canonical, Schema.BodyKinds.ghReleaseBody)
        }
        if eventKind == GitHubEventKindKey.deploymentCreated.rawValue {
            return (canonical, Schema.BodyKinds.ghDeploymentDescription)
        }
        // Track-3 D3 Task 14 — Slack canvas title body-kind dispatch.
        // Per ADR-010 §6, canvas titles are user-named structured resources
        // (not message bodies) and route through FTS via the `body` field.
        if eventKind == SlackEventKindKey.slackCanvasCreated.rawValue
            || eventKind == SlackEventKindKey.slackCanvasEdited.rawValue {
            return (canonical, Schema.BodyKinds.slackCanvasTitle)
        }
        // Track-3 D3 Task 14 — Slack bookmark title body-kind dispatch (Task 12
        // gap closed here; bookmark cases were declared body-bearing but lacked
        // a dispatch entry until canvas titles were also wired).
        if eventKind == SlackEventKindKey.slackBookmarkAdded.rawValue
            || eventKind == SlackEventKindKey.slackBookmarkRemoved.rawValue {
            return (canonical, Schema.BodyKinds.slackBookmarkTitle)
        }

        // Track-4 S4 — non-canonical payload keys (user-authored titles/filenames).
        // Per ADR-010 these are user-namespace labels (note title, meeting topic,
        // screenshot/download filenames) — mirror commit-message precedent.
        if eventKind == "notes_active_title_changed" {
            return ("note_title", Schema.BodyKinds.notesTitle)
        }
        if eventKind == "zoom_meeting_name_observed" {
            return ("meeting_topic", Schema.BodyKinds.zoomMeetingName)
        }
        if eventKind == "screenshot_taken" {
            return ("filename", Schema.BodyKinds.screenshotFilename)
        }
        if eventKind == "download_added" {
            return ("filename", Schema.BodyKinds.downloadFilename)
        }

        return nil
    }

    /// Test-only accessor for `topLevelBodyKind`. Used by `DispatchCoverageTests`
    /// fence assertion #3 (every `GitHubEventKindKey.bodyBearing` case has a
    /// dispatch entry). Returns `bodyKind` component only — `payloadKey` is an
    /// internal dispatch concern.
    public static func bodyKindForTesting(eventKind: String) -> String? {
        topLevelBodyKind(forEventKind: eventKind)?.bodyKind
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
