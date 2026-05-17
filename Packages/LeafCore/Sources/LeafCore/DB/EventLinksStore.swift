import Foundation
import GRDB
import os

/// Phase Track-1 D2 — cross-source link derivation + reverse-lookup reader.
/// Static API. Caller wraps in `pool.write {}` / `pool.read {}` per existing
/// store convention. Insert idempotency via `INSERT OR IGNORE` against the
/// composite PK (from_event_id, link_kind, target_ref).
///
/// Branch / PR-URL / PR-hash extraction is delegated through the `LinkDerivers`
/// injection struct because the concrete moat extractors live in LeafCorePrivate
/// (LeafCore cannot import LeafCorePrivate). LinearIDExtractor is in LeafCore
/// proper, so it's called directly. Reviewer fan-out is structured payload —
/// no extractor needed.
public enum EventLinksStore {

    private static let log = Logger(subsystem: "tech.gundem.leaf.core", category: "links")

    /// Lightweight inline shapes — forward-compat (extra JSON keys ignored).
    private struct BodyOnly: Decodable { let body: String }
    private struct TextOnly: Decodable { let text: String }

    /// Walks event payload + applies extractors per derivation table (spec §3.5).
    /// Empty `knownLinearPrefixes` → Linear-ID extractors short-circuit. Branch /
    /// PR-URL / PR-hash paths run only when `derivers` supplies non-no-op closures
    /// (LeafCorePrivate `prodLinkDerivers()`). Reviewer fan-out always runs.
    public static func deriveLinks(
        eventID: Int64,
        ts: Int64,
        payload: [String: String],
        knownLinearPrefixes: Set<String>,
        derivers: LinkDerivers,
        in db: GRDB.Database
    ) throws {
        let bodies = enumerateBodies(payload: payload)
        let eventKind = payload["event_kind"] ?? ""

        try deriveLinearIDInText(
            eventID: eventID, ts: ts, bodies: bodies,
            knownLinearPrefixes: knownLinearPrefixes, derivers: derivers, in: db)
        try deriveBranchNameLinearRef(
            eventID: eventID, ts: ts, payload: payload, eventKind: eventKind,
            knownLinearPrefixes: knownLinearPrefixes, derivers: derivers, in: db)
        try derivePRRefsInSlackBodies(
            eventID: eventID, ts: ts, bodies: bodies, derivers: derivers, in: db)
        try deriveReviewerAssignments(
            eventID: eventID, ts: ts, payload: payload, derivers: derivers, in: db)
        try deriveZoomToCalendarLink(
            eventID: eventID, ts: ts, payload: payload, eventKind: eventKind,
            derivers: derivers, in: db)
    }

    /// 1) Linear ID in any body — LeafCore-public extractor, no derivers needed.
    private static func deriveLinearIDInText(
        eventID: Int64, ts: Int64, bodies: [(String, String)],
        knownLinearPrefixes: Set<String>, derivers: LinkDerivers, in db: GRDB.Database
    ) throws {
        guard !knownLinearPrefixes.isEmpty else { return }
        for (_, body) in bodies {
            for id in LinearIDExtractor.extractAll(text: body, knownPrefixes: knownLinearPrefixes) {
                try insert(
                    InsertRow(
                        eventID: eventID,
                        linkKind: Schema.LinkKinds.linearIDInText,
                        targetKind: Schema.TargetKinds.linearIssue,
                        targetRef: id,
                        confidence: derivers.confidence.linearIDInText,
                        createdAtMs: ts
                    ), in: db)
            }
        }
    }

    // 2) Branch name → Linear (gh_commit_pushed only). Moat extractor via derivers.
    // Extracted from `deriveLinks` to keep dispatcher readable; 7-param signature is
    // a direct passthrough of dispatch context, not a logical group worth structifying.
    // swiftlint:disable:next function_parameter_count
    private static func deriveBranchNameLinearRef(
        eventID: Int64, ts: Int64, payload: [String: String], eventKind: String,
        knownLinearPrefixes: Set<String>, derivers: LinkDerivers, in db: GRDB.Database
    ) throws {
        guard
            eventKind == GitHubEventKindKey.commitPushed.rawValue,
            let branch = payload["branch"],
            !knownLinearPrefixes.isEmpty,
            let id = derivers.extractBranchLinearID(branch, knownLinearPrefixes)
        else { return }
        try insert(
            InsertRow(
                eventID: eventID,
                linkKind: Schema.LinkKinds.branchNameLinearRef,
                targetKind: Schema.TargetKinds.linearIssue,
                targetRef: id,
                confidence: derivers.confidence.branchNameLinearRef,
                createdAtMs: ts
            ), in: db)
    }

    /// 3) PR URL + hash-ref in Slack bodies. Moat extractors via derivers.
    private static func derivePRRefsInSlackBodies(
        eventID: Int64, ts: Int64, bodies: [(String, String)],
        derivers: LinkDerivers, in db: GRDB.Database
    ) throws {
        for (kind, body) in bodies where isSlackBody(kind) {
            for ref in derivers.extractPRURLs(body) {
                try insert(
                    InsertRow(
                        eventID: eventID,
                        linkKind: Schema.LinkKinds.prURLInSlack,
                        targetKind: Schema.TargetKinds.githubPR,
                        targetRef: ref,
                        confidence: derivers.confidence.prURLInSlack,
                        createdAtMs: ts
                    ), in: db)
            }
            for ref in derivers.extractPRHashRefs(body) {
                try insert(
                    InsertRow(
                        eventID: eventID,
                        linkKind: Schema.LinkKinds.prNumberHashRef,
                        targetKind: Schema.TargetKinds.githubPR,
                        targetRef: ref,
                        confidence: derivers.confidence.prNumberHashRef,
                        createdAtMs: ts
                    ), in: db)
            }
        }
    }

    /// 4) Requested reviewers — structured fan-out, direct (no extractor).
    private static func deriveReviewerAssignments(
        eventID: Int64, ts: Int64, payload: [String: String],
        derivers: LinkDerivers, in db: GRDB.Database
    ) throws {
        guard let raw = payload[Schema.EventPayloadKeys.requestedReviewersJson] else { return }
        for login in decodeStringList(raw) {
            try insert(
                InsertRow(
                    eventID: eventID,
                    linkKind: Schema.LinkKinds.reviewerAssigned,
                    targetKind: Schema.TargetKinds.githubUser,
                    targetRef: login,
                    confidence: derivers.confidence.reviewerAssigned,
                    createdAtMs: ts
                ), in: db)
        }
    }

    /// 5) Track-6 P5 — Zoom → Calendar link. Collector pre-computes
    /// SHA256(EKEvent.id) hash via ZoomCalendarLinker and writes it to the
    /// started-event payload; deriveLinks reads the structured field and
    /// inserts the link row.
    private static func deriveZoomToCalendarLink(
        eventID: Int64, ts: Int64, payload: [String: String], eventKind: String,
        derivers: LinkDerivers, in db: GRDB.Database
    ) throws {
        guard
            eventKind == "zoom_meeting_started",
            let linkedID = payload[Schema.EventPayloadKeys.linkedCalendarEventID],
            !linkedID.isEmpty
        else { return }
        try insert(
            InsertRow(
                eventID: eventID,
                linkKind: Schema.LinkKinds.zoomToCalendarMeeting,
                targetKind: Schema.TargetKinds.calendarEvent,
                targetRef: linkedID,
                confidence: derivers.confidence.zoomToCalendarMeeting,
                createdAtMs: ts
            ), in: db)
    }

    /// Reverse lookup — returns DISTINCT event IDs that link to the given target,
    /// optionally bounded by ts period, ordered by event ts DESC (LIMIT 200).
    public static func eventsLinkingTo(
        targetKind: String,
        targetRef: String,
        period: ClosedRange<Int64>?,
        in db: GRDB.Database
    ) throws -> [Int64] {
        let rows: [Row]
        if let period {
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT el.from_event_id AS eid
                    FROM event_links el
                    JOIN events e ON e.id = el.from_event_id
                    WHERE el.target_kind = ? AND el.target_ref = ?
                      AND e.ts BETWEEN ? AND ?
                    ORDER BY e.ts DESC
                    LIMIT 200
                    """,
                arguments: [targetKind, targetRef, period.lowerBound, period.upperBound]
            )
        } else {
            rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT el.from_event_id AS eid
                    FROM event_links el
                    JOIN events e ON e.id = el.from_event_id
                    WHERE el.target_kind = ? AND el.target_ref = ?
                    ORDER BY e.ts DESC
                    LIMIT 200
                    """,
                arguments: [targetKind, targetRef]
            )
        }
        return rows.compactMap { $0["eid"] as Int64? }
    }

    /// Forward lookup — all `EventLink` rows for one event.
    public static func linksFrom(eventID: Int64, in db: GRDB.Database) throws -> [EventLink] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT from_event_id, link_kind, target_kind, target_ref, confidence, created_at_ms
                FROM event_links
                WHERE from_event_id = ?
                ORDER BY rowid
                """,
            arguments: [eventID]
        )
        return rows.compactMap(Self.mapRow)
    }

    // MARK: - Private

    /// Column bundle for a single `event_links` row insert. Grouped to keep
    /// the writer signature digestible — every detector callsite supplies all
    /// six fields together, mirroring the `(from_event_id, link_kind,
    /// target_kind, target_ref, confidence, created_at_ms)` schema tuple.
    fileprivate struct InsertRow {
        let eventID: Int64
        let linkKind: String
        let targetKind: String
        let targetRef: String
        let confidence: Double
        let createdAtMs: Int64
    }

    private static func insert(
        _ row: InsertRow,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO event_links
                    (from_event_id, link_kind, target_kind, target_ref, confidence, created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                row.eventID, row.linkKind, row.targetKind,
                row.targetRef, row.confidence, row.createdAtMs,
            ]
        )
    }

    /// Walks the same body-bearing payload keys as `EventsFullTextStore.indexEvent`
    /// to enumerate `(bodyKind, body)` pairs. Decode failures on JSON-blob keys
    /// are logged + skipped.
    private static func enumerateBodies(payload: [String: String]) -> [(String, String)] {
        var out: [(String, String)] = []
        let eventKind = payload["event_kind"] ?? ""

        if let raw = payload[Schema.EventPayloadKeys.body],
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let kind = topLevelBodyKind(forEventKind: eventKind)
        {
            out.append((kind, raw))
        }

        if let raw = payload[Schema.EventPayloadKeys.commentBodiesJson] {
            for body in decodeStringArray(raw, key: \BodyOnly.body) {
                out.append((Schema.BodyKinds.linearComment, body))
            }
        }
        if let raw = payload[Schema.EventPayloadKeys.threadRepliesJson] {
            for text in decodeStringArray(raw, key: \TextOnly.text) {
                out.append((Schema.BodyKinds.slackThreadReply, text))
            }
        }
        if let raw = payload[Schema.EventPayloadKeys.messagesJson] {
            for text in decodeStringArray(raw, key: \TextOnly.text) {
                out.append((Schema.BodyKinds.slackMsg, text))
            }
        }
        return out
    }

    /// Static `event_kind → body_kind` dispatch table. Table-driven so adding a
    /// new mapping is a single dict entry (mirrors `EventsFullTextStore`
    /// dispatcher — the parity fence in `DispatchCoverageTests` enforces both
    /// sides stay in sync).
    ///
    /// Track-1 D2 carry-over fix (Track-3 D1): LinearCollector emits
    /// "issue_updated" (no "linear_" prefix) — parallel of the FTS dispatcher
    /// fix. Track-3 D4 closes gh_issue_* / gist / release / deployment /
    /// slack_canvas_* / slack_bookmark_* / explicit gh_pr_* cases (instead of
    /// `hasPrefix("gh_pr_")` catch-all which would spuriously match body-less
    /// kinds like `gh_pr_review_thread_resolved`).
    private static let bodyKindDispatch: [String: String] = {
        var m: [String: String] = [
            "issue_updated": Schema.BodyKinds.linearDesc,
            "linear_notification_received": Schema.BodyKinds.linearNotificationTitle,
            GitHubEventKindKey.commitPushed.rawValue: Schema.BodyKinds.commitMsg,
            GitHubEventKindKey.issueCommentAuthored.rawValue: Schema.BodyKinds.ghIssueComment,
            GitHubEventKindKey.prReviewCommentAuthored.rawValue: Schema.BodyKinds.ghPRReviewComment,
            "slack_thread_reply_aggregate": Schema.BodyKinds.slackThreadParent,
            GitHubEventKindKey.issueOpened.rawValue: Schema.BodyKinds.ghIssueComment,
            GitHubEventKindKey.issueClosed.rawValue: Schema.BodyKinds.ghIssueComment,
            GitHubEventKindKey.gistCreated.rawValue: Schema.BodyKinds.ghGistDescription,
            GitHubEventKindKey.gistUpdated.rawValue: Schema.BodyKinds.ghGistDescription,
            GitHubEventKindKey.releasePublished.rawValue: Schema.BodyKinds.ghReleaseBody,
            GitHubEventKindKey.deploymentCreated.rawValue: Schema.BodyKinds.ghDeploymentDescription,
            SlackEventKindKey.slackCanvasCreated.rawValue: Schema.BodyKinds.slackCanvasTitle,
            SlackEventKindKey.slackCanvasEdited.rawValue: Schema.BodyKinds.slackCanvasTitle,
            SlackEventKindKey.slackBookmarkAdded.rawValue: Schema.BodyKinds.slackBookmarkTitle,
            SlackEventKindKey.slackBookmarkRemoved.rawValue: Schema.BodyKinds.slackBookmarkTitle,
            GitHubEventKindKey.prOpened.rawValue: Schema.BodyKinds.ghPR,
            GitHubEventKindKey.prMerged.rawValue: Schema.BodyKinds.ghPR,
            GitHubEventKindKey.prClosed.rawValue: Schema.BodyKinds.ghPR,
        ]
        return m
    }()

    private static func topLevelBodyKind(forEventKind eventKind: String) -> String? {
        bodyKindDispatch[eventKind]
    }

    /// Test-only accessor for `topLevelBodyKind`. Used by `DispatchCoverageTests`
    /// parity fence — every `bodyBearing` event_kind across `GitHubEventKindKey`
    /// + `SlackEventKindKey` must have a dispatch entry here. Mirrors the
    /// `EventsFullTextStore.bodyKindForTesting` shim pattern (line 156).
    public static func bodyKindForTesting(eventKind: String) -> String? {
        topLevelBodyKind(forEventKind: eventKind)
    }

    private static func isSlackBody(_ kind: String) -> Bool {
        kind == Schema.BodyKinds.slackMsg
            || kind == Schema.BodyKinds.slackThreadParent
            || kind == Schema.BodyKinds.slackThreadReply
    }

    private static func decodeStringArray<T: Decodable>(_ raw: String, key: KeyPath<T, String>) -> [String] {
        guard let data = raw.data(using: .utf8) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([T].self, from: data)
            return decoded.map { $0[keyPath: key] }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            log.error(
                "EventLinksStore JSON decode failure (BodyOnly/TextOnly): \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// Decodes `["alice","bob"]`-shaped login arrays.
    private static func decodeStringList(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([String].self, from: data)
            return
                decoded
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            log.error("EventLinksStore JSON decode failure ([String]): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private static func mapRow(_ row: Row) -> EventLink? {
        guard
            let fromEventID = row["from_event_id"] as Int64?,
            let linkKind = row["link_kind"] as String?,
            let targetKind = row["target_kind"] as String?,
            let targetRef = row["target_ref"] as String?,
            let confidence = row["confidence"] as Double?,
            let createdAtMs = row["created_at_ms"] as Int64?
        else { return nil }
        return EventLink(
            fromEventID: fromEventID,
            linkKind: linkKind,
            targetKind: targetKind,
            targetRef: targetRef,
            confidence: confidence,
            createdAtMs: createdAtMs
        )
    }
}
