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
        linearPrefixes: Set<String> = [],
        in db: Database
    ) throws {
        try db.writeSQL { rawDB in
            try processDetector(kind: Schema.DetectorKinds.decision,
                                moat: moat, nowMs: nowMs,
                                linearPrefixes: linearPrefixes, in: rawDB)
        }
        try db.writeSQL { rawDB in
            try processDetector(kind: Schema.DetectorKinds.openQuestion,
                                moat: moat, nowMs: nowMs,
                                linearPrefixes: linearPrefixes, in: rawDB)
        }
        try db.writeSQL { rawDB in
            try processDetector(kind: Schema.DetectorKinds.blockerPattern,
                                moat: moat, nowMs: nowMs,
                                linearPrefixes: linearPrefixes, in: rawDB)
        }
    }

    /// Scheduled (idle-trigger) pass. Called by Agent timer (cadence wired in
    /// the Agent integration commit). Mirrors `runIncremental`'s pool wiring —
    /// takes the LeafCore `Database` so failure inside any sub-step rolls back
    /// inside a single writer transaction.
    ///
    /// Two responsibilities:
    /// 1. LinearStuck — emits a `linear_stuck` blocker for each currently-stuck
    ///    Linear issue (partial-unique idx_blockers_open dedupes across runs)
    ///    AND auto-resolves prior open `linear_stuck` blockers whose target_ref
    ///    no longer appears in the current stuck set, attributing the resolve
    ///    to the most recent `status_transition` event for that issue.
    /// 2. WhereStopped — appends one snapshot row to `where_stopped_log` if the
    ///    deriver emits an output (nil = "not idle enough yet", caller skips).
    public static func runScheduled(
        moat: DetectorMoat,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        in db: Database
    ) throws {
        try db.writeSQL { rawDB in
            // 1. LinearStuck: emit blockers + auto-resolve transitioned ones.
            let stuckHits = try moat.linearStuck.currentlyStuck(in: rawDB, nowMs: nowMs)
            let stuckRefs = Set(stuckHits.map(\.issueRef))
            for hit in stuckHits {
                _ = try BlockersStore.insertOpenIfAbsent(
                    targetKind: Schema.TargetKinds.linearIssue,
                    targetRef: hit.issueRef,
                    blockerKind: Schema.BlockerKinds.linearStuck,
                    excerpt: nil,
                    detectedByEventID: nil,
                    startedAtMs: hit.lastStatusTransitionAtMs,
                    in: rawDB
                )
            }
            try autoResolveLinearStuck(currentlyStuck: stuckRefs,
                                       nowMs: nowMs,
                                       in: rawDB)

            // 2. WhereStopped: append if deriver emits.
            // sinceMs = last snapshot time (0 on first run); deriver decides
            // whether the elapsed idle window crosses its threshold.
            let sinceMs: Int64 = (try Int64.fetchOne(rawDB, sql:
                "SELECT MAX(generated_at_ms) FROM where_stopped_log")) ?? 0
            if let out = try moat.whereStopped.derive(
                in: rawDB, sinceMs: sinceMs, untilMs: nowMs)
            {
                try WhereStoppedLogStore.append(out,
                                                generatedAtMs: nowMs,
                                                in: rawDB)
            }
        }
    }

    /// For each open `linear_stuck` blocker whose target_ref is NOT in the
    /// current stuck set, find the most recent `status_transition` event for
    /// that issue and mark the blocker resolved with that event as attribution.
    /// Issues without a recorded transition stay open — we do not fabricate a
    /// resolve timestamp (could happen if events were retention-pruned).
    ///
    /// Linear collector emits `payload.event_kind = "status_transition"` with
    /// `payload.issue_key = <REF>` (see LinearCollector.makeTransitionEvent).
    private static func autoResolveLinearStuck(currentlyStuck: Set<String>,
                                               nowMs: Int64,
                                               in db: GRDB.Database) throws {
        let openRefs: [String] = try String.fetchAll(db, sql: """
            SELECT target_ref FROM blockers
             WHERE blocker_kind = ? AND resolved_at_ms IS NULL
        """, arguments: [Schema.BlockerKinds.linearStuck])
        for ref in openRefs where !currentlyStuck.contains(ref) {
            let row = try Row.fetchOne(db, sql: """
                SELECT id, ts FROM events
                 WHERE json_extract(payload_json, '$.event_kind') = 'status_transition'
                   AND json_extract(payload_json, '$.issue_key') = ?
                 ORDER BY ts DESC LIMIT 1
            """, arguments: [ref])
            if let row {
                try BlockersStore.resolve(
                    targetKind: Schema.TargetKinds.linearIssue,
                    targetRef: ref,
                    resolvedAtMs: row["ts"],
                    resolvedByEventID: row["id"],
                    in: db
                )
            }
        }
    }

    // MARK: - Per-kind pass

    private static func processDetector(kind: String,
                                        moat: DetectorMoat,
                                        nowMs: Int64,
                                        linearPrefixes: Set<String>,
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
                             linearPrefixes: linearPrefixes,
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
                                 linearPrefixes: Set<String>,
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
                        linearIssueRef: derivedLinearRef(payload: dict, body: body,
                                                         knownPrefixes: linearPrefixes),
                        githubPRRef: dict["linked_github_pr"] as? String,
                        openedAtMs: tsMs
                    )
                    let inserted = try OpenQuestionsStore.insertOrIgnore(row, in: db)
                    if inserted { return }
                }
            case Schema.DetectorKinds.blockerPattern:
                if let hit = moat.blockerPattern.detect(body: body, kind: bodyKind) {
                    guard let (tk, tr) = blockerTarget(eventKind: eventKind, payload: dict, body: body,
                                                       linearPrefixes: linearPrefixes)
                    else { continue }
                    let inserted = try BlockersStore.insertOpenIfAbsent(
                        targetKind: tk,
                        targetRef: tr,
                        blockerKind: Schema.BlockerKinds.patternBlockedOn,
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
        // Track-1 D2 carry-over fix (Track-3 D1): LinearCollector emits
        // "issue_updated" (no "linear_" prefix). Parallel of the FTS dispatcher
        // fix in EventsFullTextStore. Notification body kind not needed here —
        // detectors only fire on outcome-bearing events (decision/question/
        // blocker), notifications are surface-only.
        if eventKind == "issue_updated" { return .linearDesc }
        if eventKind == GitHubEventKindKey.commitPushed.rawValue { return .commitMsg }
        if eventKind == GitHubEventKindKey.issueCommentAuthored.rawValue { return .ghIssueComment }
        if eventKind == GitHubEventKindKey.prReviewCommentAuthored.rawValue { return .ghPRReviewComment }
        if eventKind == "slack_thread_reply_aggregate" { return .slackThreadParent }
        // Track-3 D4 — gh_issue_* body dispatch (mirrors FTS lines 119-122).
        // Issue body indexed under same body_kind as issue comments.
        if eventKind == GitHubEventKindKey.issueOpened.rawValue
            || eventKind == GitHubEventKindKey.issueClosed.rawValue {
            return .ghIssueComment
        }
        // Track-3 D4 — gist description / release body / deployment description
        // dispatch (mirrors FTS lines 126-135). Detectors fire on these like
        // any other user-authored text body.
        if eventKind == GitHubEventKindKey.gistCreated.rawValue
            || eventKind == GitHubEventKindKey.gistUpdated.rawValue {
            return .ghGistDescription
        }
        if eventKind == GitHubEventKindKey.releasePublished.rawValue {
            return .ghReleaseBody
        }
        if eventKind == GitHubEventKindKey.deploymentCreated.rawValue {
            return .ghDeploymentDescription
        }
        // Track-3 D4 — explicit gh_pr_* cases instead of `hasPrefix("gh_pr_")`
        // catch-all (which would spuriously match `gh_pr_review_thread_resolved`
        // and `gh_pr_awaiting_review_count` — both body-less — and route them to
        // detectors with empty body strings). Mirrors FTS lines 114-118 and the
        // EventLinksStore D4 fix.
        if eventKind == GitHubEventKindKey.prOpened.rawValue
            || eventKind == GitHubEventKindKey.prMerged.rawValue
            || eventKind == GitHubEventKindKey.prClosed.rawValue {
            return .ghPR
        }
        // Phase Track-3 D3 — Slack canvas + bookmark titles. Mirrors
        // EventsFullTextStore.topLevelBodyKind so any future Slack detectors
        // (or coverage fences asserting parity between FTS + detector dispatch
        // tables) find a typed entry here.
        if eventKind == SlackEventKindKey.slackCanvasCreated.rawValue
            || eventKind == SlackEventKindKey.slackCanvasEdited.rawValue {
            return .slackCanvasTitle
        }
        if eventKind == SlackEventKindKey.slackBookmarkAdded.rawValue
            || eventKind == SlackEventKindKey.slackBookmarkRemoved.rawValue {
            return .slackBookmarkTitle
        }
        return nil
    }

    /// Test-only accessor for `topLevelBodyKind`. Returns the raw `String?`
    /// rather than the typed `BodyKind?` so `DispatchCoverageTests` can use a
    /// uniform parity-assertion shape across FTS / EventLinks / Detector
    /// dispatchers. Mirrors `EventsFullTextStore.bodyKindForTesting` (line 156)
    /// and `EventLinksStore.bodyKindForTesting`.
    public static func bodyKindForTesting(eventKind: String) -> String? {
        topLevelBodyKind(forEventKind: eventKind)?.rawValue
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
    /// over the body using the threaded prefix whitelist (Track A0 — the
    /// Agent supplies it via `LinearPrefixSource`).
    private static func derivedLinearRef(payload: [String: Any],
                                         body: String,
                                         knownPrefixes: Set<String>) -> String? {
        if let explicit = payload["linked_linear_id"] as? String, !explicit.isEmpty {
            return explicit
        }
        let matches = LinearIDExtractor.extractAll(text: body, knownPrefixes: knownPrefixes)
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
                                      body: String,
                                      linearPrefixes: Set<String>) -> (String, String)? {
        if let linRef = derivedLinearRef(payload: payload, body: body,
                                         knownPrefixes: linearPrefixes) {
            return (Schema.TargetKinds.linearIssue, linRef)
        }
        if let prRef = payload["linked_github_pr"] as? String, !prRef.isEmpty {
            return (Schema.TargetKinds.githubPR, prRef)
        }
        return nil
    }
}
