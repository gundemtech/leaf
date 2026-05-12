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

        // 1) Linear ID in any body — LeafCore-public extractor, no derivers needed.
        if !knownLinearPrefixes.isEmpty {
            for (_, body) in bodies {
                for id in LinearIDExtractor.extractAll(text: body, knownPrefixes: knownLinearPrefixes) {
                    try insert(eventID: eventID,
                               linkKind: Schema.LinkKinds.linearIDInText,
                               targetKind: Schema.TargetKinds.linearIssue,
                               targetRef: id,
                               confidence: derivers.confidence.linearIDInText,
                               createdAtMs: ts, in: db)
                }
            }
        }

        // 2) Branch name → Linear (gh_commit_pushed only). Moat extractor via derivers.
        if eventKind == GitHubEventKindKey.commitPushed.rawValue,
           let branch = payload["branch"],
           !knownLinearPrefixes.isEmpty,
           let id = derivers.extractBranchLinearID(branch, knownLinearPrefixes) {
            try insert(eventID: eventID,
                       linkKind: Schema.LinkKinds.branchNameLinearRef,
                       targetKind: Schema.TargetKinds.linearIssue,
                       targetRef: id,
                       confidence: derivers.confidence.branchNameLinearRef,
                       createdAtMs: ts, in: db)
        }

        // 3) PR URL + hash-ref in Slack bodies. Moat extractors via derivers.
        for (kind, body) in bodies where isSlackBody(kind) {
            for ref in derivers.extractPRURLs(body) {
                try insert(eventID: eventID,
                           linkKind: Schema.LinkKinds.prURLInSlack,
                           targetKind: Schema.TargetKinds.githubPR,
                           targetRef: ref,
                           confidence: derivers.confidence.prURLInSlack,
                           createdAtMs: ts, in: db)
            }
            for ref in derivers.extractPRHashRefs(body) {
                try insert(eventID: eventID,
                           linkKind: Schema.LinkKinds.prNumberHashRef,
                           targetKind: Schema.TargetKinds.githubPR,
                           targetRef: ref,
                           confidence: derivers.confidence.prNumberHashRef,
                           createdAtMs: ts, in: db)
            }
        }

        // 4) Requested reviewers — structured fan-out, direct (no extractor).
        if let raw = payload[Schema.EventPayloadKeys.requestedReviewersJson] {
            for login in decodeStringList(raw) {
                try insert(eventID: eventID,
                           linkKind: Schema.LinkKinds.reviewerAssigned,
                           targetKind: Schema.TargetKinds.githubUser,
                           targetRef: login,
                           confidence: derivers.confidence.reviewerAssigned,
                           createdAtMs: ts, in: db)
            }
        }
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

    private static func insert(
        eventID: Int64,
        linkKind: String,
        targetKind: String,
        targetRef: String,
        confidence: Double,
        createdAtMs: Int64,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO event_links
                    (from_event_id, link_kind, target_kind, target_ref, confidence, created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [eventID, linkKind, targetKind, targetRef, confidence, createdAtMs]
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
           let kind = topLevelBodyKind(forEventKind: eventKind) {
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

    private static func topLevelBodyKind(forEventKind eventKind: String) -> String? {
        // Track-1 D2 carry-over fix (Track-3 D1): LinearCollector emits
        // "issue_updated" (no "linear_" prefix) — parallel of the FTS dispatcher
        // fix in EventsFullTextStore. Also adds linear_notification_received
        // dispatch ahead of Task 8.
        if eventKind == "issue_updated" { return Schema.BodyKinds.linearDesc }
        if eventKind == "linear_notification_received" { return Schema.BodyKinds.linearNotificationTitle }
        if eventKind == GitHubEventKindKey.commitPushed.rawValue { return Schema.BodyKinds.commitMsg }
        if eventKind == GitHubEventKindKey.issueCommentAuthored.rawValue { return Schema.BodyKinds.ghIssueComment }
        if eventKind == GitHubEventKindKey.prReviewCommentAuthored.rawValue { return Schema.BodyKinds.ghPRReviewComment }
        if eventKind == "slack_thread_reply_aggregate" { return Schema.BodyKinds.slackThreadParent }
        // Track-3 D4 — gh_issue_* body dispatch. Issue body indexed under the
        // same body_kind as issue comments (mirrors FTS lines 119-122).
        if eventKind == GitHubEventKindKey.issueOpened.rawValue
            || eventKind == GitHubEventKindKey.issueClosed.rawValue {
            return Schema.BodyKinds.ghIssueComment
        }
        // Track-3 D4 — gist description / release body / deployment description
        // dispatch (mirrors FTS lines 126-135). Missed in D2 — closed here.
        if eventKind == GitHubEventKindKey.gistCreated.rawValue
            || eventKind == GitHubEventKindKey.gistUpdated.rawValue {
            return Schema.BodyKinds.ghGistDescription
        }
        if eventKind == GitHubEventKindKey.releasePublished.rawValue {
            return Schema.BodyKinds.ghReleaseBody
        }
        if eventKind == GitHubEventKindKey.deploymentCreated.rawValue {
            return Schema.BodyKinds.ghDeploymentDescription
        }
        // Track-3 D4 — Slack canvas + bookmark titles (D3 §4.3). Per ADR-010 §6,
        // canvas/bookmark titles are user-named structured resources (not
        // message bodies); body field is FTS-indexed AND a target for
        // cross-source link derivation (e.g. LEAF-NN refs inside canvas titles).
        // Mirrors FTS lines 139-149.
        if eventKind == SlackEventKindKey.slackCanvasCreated.rawValue
            || eventKind == SlackEventKindKey.slackCanvasEdited.rawValue {
            return Schema.BodyKinds.slackCanvasTitle
        }
        if eventKind == SlackEventKindKey.slackBookmarkAdded.rawValue
            || eventKind == SlackEventKindKey.slackBookmarkRemoved.rawValue {
            return Schema.BodyKinds.slackBookmarkTitle
        }
        if eventKind.hasPrefix("gh_pr_") { return Schema.BodyKinds.ghPR }
        return nil
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
            log.error("EventLinksStore JSON decode failure (BodyOnly/TextOnly): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Decodes `["alice","bob"]`-shaped login arrays.
    private static func decodeStringList(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([String].self, from: data)
            return decoded
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
            let linkKind    = row["link_kind"] as String?,
            let targetKind  = row["target_kind"] as String?,
            let targetRef   = row["target_ref"] as String?,
            let confidence  = row["confidence"] as Double?,
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
