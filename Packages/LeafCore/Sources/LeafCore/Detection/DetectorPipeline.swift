import Foundation
import GRDB
import os

/// Phase Track-1 D3 — per-event detector pipeline.
///
/// `runIncremental` is a cursor-based batch pass invoked by Agent after each
/// collector flush. It reads new events since the per-detector cursor,
/// dispatches body-bearing payload fields to decision / open_question /
/// blocker_pattern detectors via the same body-kind table used by D2's
/// `EventsFullTextStore.indexEvent`, and writes detector tables under
/// INSERT OR IGNORE for per-event idempotency.
///
/// Per-event uniqueness: at most ONE hit per event per detector kind. First
/// matching body wins (tie-broken by body_kind dispatch order).
///
/// Pool wiring: takes the LeafCore `Database` wrapper rather than a raw
/// `DatabasePool`. The pipeline runs inside `db.writeSQL { ... }` (one writer
/// transaction per detector kind) so failure inside any single detector kind
/// rolls back its writes + cursor advance atomically. This keeps the moat
/// boundary intact (raw `DatabasePool` is not part of the public API).
public enum DetectorPipeline {

    private static let log = Logger(subsystem: "tech.gundem.leaf.core", category: "detectors")

    /// Per-event cursor pass. Called by Agent after `writeEventsOffsetAndPresence`.
    /// Resolution flow + scheduled detectors land in subsequent commits.
    public static func runIncremental(
        moat: DetectorMoat,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        in db: Database
    ) throws {
        try db.writeSQL { rawDB in
            try processDetector(kind: Schema.DetectorKinds.decision,
                                moat: moat, nowMs: nowMs, in: rawDB)
        }
        try db.writeSQL { rawDB in
            try processDetector(kind: Schema.DetectorKinds.openQuestion,
                                moat: moat, nowMs: nowMs, in: rawDB)
        }
        try db.writeSQL { rawDB in
            try processDetector(kind: Schema.DetectorKinds.blockerPattern,
                                moat: moat, nowMs: nowMs, in: rawDB)
        }
    }

    // MARK: - Per-kind pass

    private static func processDetector(kind: String,
                                        moat: DetectorMoat,
                                        nowMs: Int64,
                                        in db: GRDB.Database) throws {
        let cursor = try DetectorOffsetsStore.cursor(detectorKind: kind, in: db)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, ts, signal_type, payload_json
              FROM events WHERE id > ? ORDER BY id ASC
            """, arguments: [cursor])

        var lastID: Int64 = cursor
        for row in rows {
            let eventID: Int64 = row["id"]
            let tsMs: Int64 = row["ts"]
            let signalType: String = row["signal_type"]
            let payloadJSON: String = (row["payload_json"] as String?) ?? "{}"
            do {
                try dispatch(eventID: eventID,
                             tsMs: tsMs,
                             signalType: signalType,
                             payloadJSON: payloadJSON,
                             detectorKind: kind,
                             moat: moat,
                             in: db)
            } catch {
                // Detector failure must not break the write path — moat-impl bugs
                // are isolated; cursor still advances past the offending event.
                log.error("detector \(kind, privacy: .public) failed on event \(eventID): \(String(describing: error), privacy: .public)")
            }
            lastID = eventID
        }

        try DetectorOffsetsStore.advance(detectorKind: kind,
                                         toEventID: lastID,
                                         nowMs: nowMs,
                                         in: db)
    }

    // MARK: - Body dispatch

    private static func dispatch(eventID: Int64,
                                 tsMs: Int64,
                                 signalType: String,
                                 payloadJSON: String,
                                 detectorKind: String,
                                 moat: DetectorMoat,
                                 in db: GRDB.Database) throws {
        guard let data = payloadJSON.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let eventKind = (dict["event_kind"] as? String) ?? ""
        let bodies = extractBodies(eventKind: eventKind, payload: dict)
        guard !bodies.isEmpty else { return }

        for (body, bodyKind) in bodies {
            switch detectorKind {
            case Schema.DetectorKinds.decision:
                if let hit = moat.decision.detect(body: body, kind: bodyKind, eventTsMs: tsMs) {
                    let inserted = try DecisionsStore.insertOrIgnore(
                        eventID: eventID, hit: hit, detectedAtMs: tsMs, in: db)
                    if inserted {
                        // Same transaction as the INSERT — failure rolls back both.
                        let contexts = try resolutionContexts(eventID: eventID,
                                                              payload: dict,
                                                              in: db)
                        _ = try OpenQuestionsStore.markResolved(
                            matchingContexts: contexts,
                            resolvedByEventID: eventID,
                            resolvedAtMs: tsMs,
                            in: db)
                        return
                    }
                }
            case Schema.DetectorKinds.openQuestion:
                if let hit = moat.openQuestion.detect(body: body, kind: bodyKind) {
                    let row = OpenQuestionRow(
                        eventID: eventID,
                        hit: hit,
                        slackThreadTS: dict["thread_ts"] as? String,
                        linearIssueRef: derivedLinearRef(payload: dict, body: body),
                        githubPRRef: dict["linked_github_pr"] as? String,
                        openedAtMs: tsMs
                    )
                    let inserted = try OpenQuestionsStore.insertOrIgnore(row, in: db)
                    if inserted { return }
                }
            case Schema.DetectorKinds.blockerPattern:
                if let hit = moat.blockerPattern.detect(body: body, kind: bodyKind) {
                    guard let (tk, tr) = blockerTarget(eventKind: eventKind, payload: dict, body: body)
                    else { continue }
                    let inserted = try BlockersStore.insertOpenIfAbsent(
                        targetKind: tk,
                        targetRef: tr,
                        blockerKind: "pattern_blocked_on",
                        excerpt: hit.blockerExcerpt,
                        detectedByEventID: eventID,
                        startedAtMs: tsMs,
                        in: db
                    )
                    if inserted { return }
                }
            default:
                return
            }
        }
    }

    // MARK: - Body extraction (mirrors EventsFullTextStore.indexEvent)

    /// Extracts `(body, kind)` pairs from a payload dict, in dispatch order.
    /// Top-level body first (per event_kind), then JSON-array fan-outs.
    private static func extractBodies(eventKind: String,
                                      payload: [String: Any]) -> [(String, BodyKind)] {
        var out: [(String, BodyKind)] = []

        if let raw = payload[Schema.EventPayloadKeys.body] as? String,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let kind = topLevelBodyKind(forEventKind: eventKind) {
            out.append((raw, kind))
        }

        // Linear comments fan-out.
        if let raw = payload[Schema.EventPayloadKeys.commentBodiesJson] as? String {
            for body in decodeStringArray(raw, key: "body") {
                out.append((body, .linearComment))
            }
        }
        // Slack thread replies fan-out.
        if let raw = payload[Schema.EventPayloadKeys.threadRepliesJson] as? String {
            for text in decodeStringArray(raw, key: "text") {
                out.append((text, .slackThreadReply))
            }
        }
        // Slack messages aggregate fan-out.
        if let raw = payload[Schema.EventPayloadKeys.messagesJson] as? String {
            for text in decodeStringArray(raw, key: "text") {
                out.append((text, .slackMsg))
            }
        }
        return out
    }

    private static func topLevelBodyKind(forEventKind eventKind: String) -> BodyKind? {
        if eventKind == "linear_issue_updated" { return .linearDesc }
        if eventKind == "commit_pushed" { return .commitMsg }
        if eventKind == "gh_issue_comment_authored" { return .ghIssueComment }
        if eventKind == "gh_pr_review_comment_authored" { return .ghPRReviewComment }
        if eventKind == "slack_thread_reply_aggregate" { return .slackThreadParent }
        if eventKind.hasPrefix("gh_pr_") { return .ghPR }
        return nil
    }

    private static func decodeStringArray(_ raw: String, key: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { $0[key] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Context-ref derivation

    /// Resolves the linear_issue_ref for an OpenQuestion row.
    /// Prefers the explicit `linked_linear_id` payload key (Phase 4.7.A) so
    /// that issues already attributed by the collector are not re-extracted
    /// from body text. Falls back to first match from `LinearIDExtractor`
    /// over the body — `knownPrefixes` is empty here; production wiring
    /// (Agent integration commit) threads the prefix set through.
    private static func derivedLinearRef(payload: [String: Any], body: String) -> String? {
        if let explicit = payload["linked_linear_id"] as? String, !explicit.isEmpty {
            return explicit
        }
        let matches = LinearIDExtractor.extractAll(text: body, knownPrefixes: Set<String>())
        return matches.first
    }

    /// Builds resolution context for a "verdict" event (the decision that may
    /// answer prior open questions). Combines collector-attributed payload
    /// keys (`thread_ts` / `linked_linear_id` / `linked_github_pr`) with the
    /// D2 link graph so cross-source decisions (e.g. Slack DECIDE that links
    /// back to a Linear issue or GitHub PR via event_links) still resolve.
    private static func resolutionContexts(eventID: Int64,
                                           payload: [String: Any],
                                           in db: GRDB.Database) throws -> ResolutionContexts {
        let threadTS = payload["thread_ts"] as? String

        var linearRefs = Set<String>()
        if let s = payload["linked_linear_id"] as? String, !s.isEmpty {
            linearRefs.insert(s)
        }
        var prRefs = Set<String>()
        if let s = payload["linked_github_pr"] as? String, !s.isEmpty {
            prRefs.insert(s)
        }

        for link in try EventLinksStore.linksFrom(eventID: eventID, in: db) {
            switch link.targetKind {
            case Schema.TargetKinds.linearIssue:
                linearRefs.insert(link.targetRef)
            case Schema.TargetKinds.githubPR:
                prRefs.insert(link.targetRef)
            default:
                continue
            }
        }

        return ResolutionContexts(
            slackThreadTS: threadTS,
            linearIssueRefs: Array(linearRefs),
            githubPRRefs: Array(prRefs)
        )
    }

    /// Picks `(target_kind, target_ref)` for blocker writes.
    /// Linear-attributed events → linear_issue; GitHub-attributed → github_pr.
    /// No target → caller skips the insert (we do not fabricate one).
    private static func blockerTarget(eventKind: String,
                                      payload: [String: Any],
                                      body: String) -> (String, String)? {
        if let linRef = derivedLinearRef(payload: payload, body: body) {
            return (Schema.TargetKinds.linearIssue, linRef)
        }
        if let prRef = payload["linked_github_pr"] as? String, !prRef.isEmpty {
            return (Schema.TargetKinds.githubPR, prRef)
        }
        return nil
    }
}
