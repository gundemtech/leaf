import Foundation
import GRDB
import os

/// Phase Track-1 D3 — query-side composition over events + FTS + links +
/// detector tables, exposed to MCP tool handlers.
///
/// Three composition methods:
///   * `queryActivity(period:filter:)` — period+filter scoped activity feed,
///     with detector outputs + cross-source links + on-the-fly absence flags.
///     SQL `LIMIT 200` + post-serialize 64KB byte budget with oldest-event
///     trim and `truncationNote`.
///   * `getDecision(topic:period:)` — FTS over event bodies, ranked by
///     decision confidence + recency; returns top-1 with originating event
///     projection + outbound links.
///   * `currentWork(nowMs:)` — latest-event projections for the
///     `leaf_current_work` MCP tool.
///
/// Read-only: each call opens `Database.openForRead(...)` per existing 12 MCP
/// tools' pattern. `bodyExcerptCharCap` defaults to 500 (substrate); production
/// callers thread the moat-supplied cap through.
public struct QueryEngine: Sendable {

    private static let log = Logger(subsystem: "tech.gundem.leaf.core", category: "query-engine")

    /// Hard SQL `LIMIT` for `events[]` projection. Backstop ahead of byte-budget
    /// trim so we never decode 100k events to immediately drop them.
    static let sqlEventLimit = 200

    /// MCP per-response byte budget. AI clients tend to reject larger payloads
    /// outright; we trim deterministically (oldest-first) and surface a
    /// `truncationNote` so the caller knows. Measured against `.sortedKeys`
    /// canonical encoding — the MCP server uses the same shape so the budget
    /// holds end-to-end.
    static let byteBudget = 65_536

    /// Candidate-event cap for FTS-routed `getDecision` topic match. Decisions
    /// table has UNIQUE event_id, so 50 candidates → at most 50 decision rows
    /// to rank by confidence/recency.
    static let decisionTopicCandidateLimit = 50

    /// `currentWork.whereStopped` only surfaces the latest log row if generated
    /// within this window — older entries are stale and worse than nothing.
    static let whereStoppedFreshnessWindowMs: Int64 = 24 * 60 * 60 * 1000

    public let dbURL: URL
    public let dbConfig: DatabaseConfig
    public let dbEncryption: EncryptionOptions?
    public let detectorMoat: DetectorMoat
    public let bodyExcerptCharCap: Int
    /// Track B0 — work-app classification for currentWork projections.
    public let workAppHeuristic: WorkAppHeuristic

    public init(
        dbURL: URL,
        dbConfig: DatabaseConfig,
        dbEncryption: EncryptionOptions?,
        detectorMoat: DetectorMoat,
        bodyExcerptCharCap: Int = 500,
        workAppHeuristic: WorkAppHeuristic = .standard
    ) {
        self.dbURL = dbURL
        self.dbConfig = dbConfig
        self.dbEncryption = dbEncryption
        self.detectorMoat = detectorMoat
        self.bodyExcerptCharCap = bodyExcerptCharCap
        self.workAppHeuristic = workAppHeuristic
    }

    /// Track B0 — newest own PR with no later merged/closed event for the same
    /// repo#number. Local memory has no live PR state; absence of a terminal
    /// event among captured history is the best honest signal.
    static func latestOpenPR(in db: GRDB.Database) throws -> OpenPRRef? {
        let candidates = try Row.fetchAll(db, sql: """
            SELECT ts,
                   json_extract(payload_json, '$.repo')           AS repo,
                   json_extract(payload_json, '$.number')         AS number,
                   json_extract(payload_json, '$.title')          AS title,
                   json_extract(payload_json, '$.comments_count') AS comments_count
              FROM events
             WHERE json_extract(payload_json, '$.event_kind') = 'gh_pr_opened'
               AND json_extract(payload_json, '$.number') IS NOT NULL
               AND json_extract(payload_json, '$.number') != ''
             ORDER BY ts DESC LIMIT 10
        """)
        for row in candidates {
            guard let repo: String = row["repo"], !repo.isEmpty,
                  let number: String = row["number"] else { continue }
            let terminal = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM events
                     WHERE json_extract(payload_json, '$.event_kind')
                           IN ('gh_pr_merged', 'gh_pr_closed')
                       AND json_extract(payload_json, '$.repo') = ?
                       AND json_extract(payload_json, '$.number') = ?
                )
            """, arguments: [repo, number]) ?? false
            if terminal { continue }
            return OpenPRRef(
                ref: "\(repo)#\(number)",
                title: row["title"] as String?,
                commentCount: (row["comments_count"] as String?).flatMap(Int.init),
                url: "https://github.com/\(repo)/pull/\(number)",
                openedAtMs: row["ts"] as Int64?
            )
        }
        return nil
    }

    // MARK: - queryActivity

    public func queryActivity(period: PeriodSpec,
                              filter: String?) throws -> QueryActivityResponse {
        let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        return try db.readSQL { rawDB -> QueryActivityResponse in
            // 1. Event-id set: FTS branch when filter present + non-empty,
            //    fallback to recent-events SELECT otherwise.
            let eventIDs: [Int64]
            if let filter, !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                eventIDs = try EventsFullTextStore.search(
                    query: filter,
                    period: period.startMs ... period.endMs,
                    limit: Self.sqlEventLimit,
                    in: rawDB
                )
            } else {
                // Track A4 — unfiltered feed shows substance only: provider
                // pulses / token accounting / bare attention pings drowned the
                // actual work output (live finding 2026-06-11).
                eventIDs = try Int64.fetchAll(rawDB, sql: """
                    SELECT id FROM events
                     WHERE ts BETWEEN ? AND ?
                       AND \(EventKindTaxonomy.substanceSQLPredicate())
                     ORDER BY ts DESC LIMIT ?
                """, arguments: [period.startMs, period.endMs, Self.sqlEventLimit])
            }

            // 2. Project events (slim shape, body excerpt capped).
            let events = try projectEvents(eventIDs: eventIDs, in: rawDB)

            // 3. Decisions in period: include both event-attributed (id IN ...)
            //    AND any decision detected within the period window (covers
            //    detectors that ran late vs the original event ts).
            let decisions = try fetchDecisionsForResponse(eventIDs: eventIDs, period: period, in: rawDB)

            // 4. Open questions: same dual-clause shape (event_id OR opened_at_ms).
            let openQs = try fetchOpenQuestionsForResponse(eventIDs: eventIDs, period: period, in: rawDB)

            // 5. Blockers: started_at_ms OR resolved_at_ms within period.
            let blockers = try fetchBlockersForResponse(period: period, in: rawDB)

            // 6. Links: outbound from any projected event.
            let links = try fetchLinksForResponse(eventIDs: eventIDs, in: rawDB)

            // 7. Absence flags: per-PR per-reviewer at query time.
            let absenceFlags = try computeAbsenceFlags(events: events, in: rawDB)

            let response = QueryActivityResponse(
                period: period,
                filter: filter,
                events: events,
                decisionsInPeriod: decisions,
                openQuestions: openQs,
                blockers: blockers,
                links: links,
                absenceFlags: absenceFlags,
                truncationNote: nil
            )

            // 8. Encode + enforce byte budget — drop oldest event(s) until under cap.
            return try enforceByteBudget(response, originalEventCount: events.count)
        }
    }

    // MARK: - getDecision

    public func getDecision(topic: String, period: PeriodSpec?) throws -> GetDecisionResponse {
        let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        return try db.readSQL { rawDB -> GetDecisionResponse in
            // Period defaults to the widest representable range when caller
            // doesn't scope; `EventsFullTextStore.search` filters by events.ts.
            let range: ClosedRange<Int64>
            if let p = period {
                range = p.startMs ... p.endMs
            } else {
                range = Int64.min ... Int64.max
            }

            // FTS over event bodies — events_fts is contentless over
            // `events.payload.body`, not `decisions.reasoning_excerpt`. Topic
            // match → candidate event ids → join to `decisions` table to find
            // the highest-confidence decision pinned to one of those events.
            let candidateIDs = try EventsFullTextStore.search(
                query: topic, period: range, limit: Self.decisionTopicCandidateLimit, in: rawDB
            )
            guard !candidateIDs.isEmpty else {
                return GetDecisionResponse(decision: nil, relatedEvents: [], truncationNote: nil)
            }

            let placeholders = Array(repeating: "?", count: candidateIDs.count).joined(separator: ",")
            let row = try Row.fetchOne(rawDB, sql: """
                SELECT id, event_id, topic_keywords_json, reasoning_excerpt, confidence, detected_at_ms
                  FROM decisions
                 WHERE event_id IN (\(placeholders))
                 ORDER BY confidence DESC, detected_at_ms DESC
                 LIMIT 1
            """, arguments: StatementArguments(candidateIDs))

            guard let row else {
                return GetDecisionResponse(decision: nil, relatedEvents: [], truncationNote: nil)
            }

            let decisionView = decisionView(from: row)
            let originatingEventID = decisionView.eventID
            let originatingEvent = try projectEvents(
                eventIDs: [originatingEventID], in: rawDB
            ).first ?? Self.placeholderEvent(eventID: originatingEventID)

            // Outbound links from the originating event = pointers to
            // implementation (Linear ticket / GitHub PR / Slack thread).
            let linksFromOrigin = try EventLinksStore.linksFrom(eventID: originatingEventID, in: rawDB)
            let linkViews = linksFromOrigin.map(LinkView.init(from:))

            // Related events: every event that the originating event links TO
            // (forward) AND every event that shares those targets (siblings).
            // We approximate as "events linking to any of those targets" via
            // EventLinksStore.eventsLinkingTo.
            var relatedSet = Set<Int64>()
            for link in linksFromOrigin {
                let ids = try EventLinksStore.eventsLinkingTo(
                    targetKind: link.targetKind,
                    targetRef: link.targetRef,
                    period: nil,
                    in: rawDB
                )
                for id in ids where id != originatingEventID {
                    relatedSet.insert(id)
                }
            }
            let relatedEvents = try projectEvents(eventIDs: Array(relatedSet), in: rawDB)

            return GetDecisionResponse(
                decision: DecisionDetail(
                    decision: decisionView,
                    originatingEvent: originatingEvent,
                    linksToImplementation: linkViews
                ),
                relatedEvents: relatedEvents,
                truncationNote: nil
            )
        }
    }

    // MARK: - currentWork

    public func currentWork(nowMs: Int64) throws -> CurrentWorkResponse {
        let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        return try db.readSQL { rawDB -> CurrentWorkResponse in
            // Track B0 — current app/file must describe WORK. The literal
            // latest attention event reported messengers/music as "current
            // work" (live finding 2026-06-11). Scan the recent attention
            // window for the first dev-relevant bundle; fail closed (nil)
            // when there is none. App + file come from the SAME row so they
            // can never describe two different apps.
            let attentionRows = try Row.fetchAll(rawDB, sql: """
                SELECT bundle_id, json_extract(payload_json, '$.window_title') AS window_title
                  FROM events
                 WHERE signal_type = 'attention' AND bundle_id IS NOT NULL
                 ORDER BY ts DESC LIMIT 50
            """)
            var currentApp: String?
            var currentFile: String?
            for row in attentionRows {
                guard let bundle: String = row["bundle_id"],
                      workAppHeuristic.isDevRelevant(bundle) else { continue }
                if currentApp == nil { currentApp = bundle }
                if currentFile == nil,
                   let title: String = row["window_title"], !title.isEmpty,
                   bundle == currentApp {
                    currentFile = title
                }
                if currentApp != nil, currentFile != nil { break }
                // Keep scanning only for a title of the SAME app.
                if currentApp != nil, bundle != currentApp { break }
            }

            // in_progress_linear_ticket: latest issue_updated whose status != 'Done'.
            // Linear collector emits payload.event_kind = "issue_updated" + payload.status.
            let linearTicket: LinearTicketRef? = try Row.fetchOne(rawDB, sql: """
                SELECT json_extract(payload_json, '$.issue_key')   AS issue_ref,
                       json_extract(payload_json, '$.title')       AS title,
                       json_extract(payload_json, '$.status')      AS status
                  FROM events
                 WHERE json_extract(payload_json, '$.event_kind') = 'issue_updated'
                   AND COALESCE(json_extract(payload_json, '$.status'), '') != 'Done'
                   AND json_extract(payload_json, '$.issue_key') IS NOT NULL
                 ORDER BY ts DESC LIMIT 1
            """).flatMap { row -> LinearTicketRef? in
                guard let ref: String = row["issue_ref"] else { return nil }
                return LinearTicketRef(
                    issueRef: ref,
                    title: row["title"] as String?,
                    stateName: row["status"] as String?
                )
            }

            // last_commit: latest commit event across BOTH sources — the
            // GitHub feed (push facts, often message-less) and the local git
            // collector (full subjects). One row feeds sha/message/branch/repo
            // AND currentBranch below — branch and commit can never disagree
            // by construction (Track B0; they used to come from separate
            // queries and routinely described different repos).
            let lastCommitRow = try Row.fetchOne(rawDB, sql: """
                SELECT ts,
                       json_extract(payload_json, '$.sha')     AS sha,
                       json_extract(payload_json, '$.body')    AS message,
                       json_extract(payload_json, '$.branch')  AS branch,
                       json_extract(payload_json, '$.repo')    AS repo
                  FROM events
                 WHERE json_extract(payload_json, '$.event_kind')
                       IN ('gh_commit_pushed', 'git_commit_authored')
                 ORDER BY ts DESC LIMIT 1
            """)
            let lastCommit: CommitRef? = lastCommitRow.map { row in
                let message: String? = row["message"]
                return CommitRef(
                    sha: row["sha"] as String?,
                    message: message,
                    branch: row["branch"] as String?,
                    pushedAtMs: row["ts"] as Int64?,
                    subject: message.flatMap {
                        $0.split(separator: "\n", maxSplits: 1).first.map(String.init)
                    },
                    repoFullName: row["repo"] as String?
                )
            }

            // Track B0 — newest still-open own PR (no later merged/closed
            // event for the same repo#number among the recent candidates).
            let openPR: OpenPRRef? = try Self.latestOpenPR(in: rawDB)

            // Track B0 — latest Slack thread/channel activity (aggregates
            // carry channel_name + count; bodies never surface here).
            let lastThread: ThreadRef? = try Row.fetchOne(rawDB, sql: """
                SELECT ts,
                       json_extract(payload_json, '$.channel_name') AS channel_name,
                       json_extract(payload_json, '$.count')        AS msg_count
                  FROM events
                 WHERE json_extract(payload_json, '$.event_kind')
                       IN ('slack_thread_reply_aggregate', 'slack_message_authored_aggregate')
                   AND json_extract(payload_json, '$.channel_name') IS NOT NULL
                 ORDER BY ts DESC LIMIT 1
            """).flatMap { row -> ThreadRef? in
                guard let channel: String = row["channel_name"], !channel.isEmpty else { return nil }
                return ThreadRef(
                    channelName: channel,
                    messageCount: (row["msg_count"] as String?).flatMap(Int.init),
                    tsMs: row["ts"] as Int64?
                )
            }

            // current_open_questions: limit 20, unresolved.
            let openQs = try Row.fetchAll(rawDB, sql: """
                SELECT id, event_id, question_excerpt, alternatives_json,
                       slack_thread_ts, linear_issue_ref, github_pr_ref,
                       resolved_by_event_id, opened_at_ms, resolved_at_ms
                  FROM open_questions
                 WHERE resolved_at_ms IS NULL
                 ORDER BY opened_at_ms DESC LIMIT 20
            """).map(Self.openQuestionView(from:))

            // current_blockers: limit 10, unresolved.
            let blockers = try Row.fetchAll(rawDB, sql: """
                SELECT id, target_kind, target_ref, blocker_kind, blocker_excerpt,
                       detected_by_event_id, started_at_ms, resolved_at_ms,
                       resolved_by_event_id
                  FROM blockers
                 WHERE resolved_at_ms IS NULL
                 ORDER BY started_at_ms DESC LIMIT 10
            """).map(Self.blockerView(from:))

            // where_stopped: latest where_stopped_log row IF generated within
            // the last 24h (older snapshots are stale for "current work").
            let whereStopped: WhereStoppedOutput? = try {
                guard let row = try WhereStoppedLogStore.latest(in: rawDB),
                      let generatedAtMs: Int64 = row["generated_at_ms"]
                else { return nil }
                guard nowMs - generatedAtMs <= Self.whereStoppedFreshnessWindowMs else { return nil }
                let excerpt: String = (row["excerpt"] as String?) ?? ""
                let anchor: Int64? = row["anchor_event_id"] as Int64?
                let wipJSON: String? = row["wip_signals_json"] as String?
                let wip: WipSignals
                if let wipJSON, let data = wipJSON.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(WipSignals.self, from: data) {
                    wip = decoded
                } else {
                    wip = WipSignals(commitWip: false, ciFailing: false, midEdit: false)
                }
                return WhereStoppedOutput(excerpt: excerpt, wipSignals: wip, anchorEventID: anchor)
            }()

            return CurrentWorkResponse(
                currentApp: currentApp,
                currentBranch: lastCommit?.branch,
                currentFile: currentFile,
                inProgressLinearTicket: linearTicket,
                lastCommit: lastCommit,
                openPR: openPR,
                lastThread: lastThread,
                currentOpenQuestions: openQs,
                currentBlockers: blockers,
                whereStopped: whereStopped
            )
        }
    }

    // MARK: - Projection helpers

    /// Decode events by id list → slim ActivityEvent. Returns events ordered ts DESC.
    /// (Caller order is not preserved — we re-sort after fetch so byte-budget
    /// trim discipline ("oldest-last") works regardless of input order.)
    private func projectEvents(eventIDs: [Int64], in db: GRDB.Database) throws -> [ActivityEvent] {
        guard !eventIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, ts, signal_type, bundle_id, payload_json
              FROM events WHERE id IN (\(placeholders))
              ORDER BY ts DESC
        """, arguments: StatementArguments(eventIDs))
        let projected = rows.map { row -> ActivityEvent in
            let id: Int64 = row["id"]
            let ts: Int64 = row["ts"]
            let signalType: String = row["signal_type"]
            let bundleID: String? = row["bundle_id"] as String?
            let payloadJSON: String = (row["payload_json"] as String?) ?? "{}"

            var eventKind: String?
            var bodyExcerpt: String?
            var bodyTruncated = false
            var targetRef: String?
            var targetTitle: String?
            if let data = payloadJSON.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                eventKind = dict["event_kind"] as? String
                if let body = dict[Schema.EventPayloadKeys.body] as? String, !body.isEmpty {
                    let (excerpt, truncated) = BodyExcerpt.capped(body, charCap: bodyExcerptCharCap)
                    bodyExcerpt = excerpt
                    bodyTruncated = truncated
                }
                // Structured target handle — all allowlisted payload keys.
                if let issueKey = dict["issue_key"] as? String, !issueKey.isEmpty {
                    targetRef = issueKey
                } else if let repo = (dict["repo_full_name"] as? String) ?? (dict["repo"] as? String),
                          !repo.isEmpty {
                    if let number = dict["number"] as? String, !number.isEmpty {
                        targetRef = "\(repo)#\(number)"
                    } else {
                        targetRef = repo
                    }
                }
                if let title = dict["title"] as? String, !title.isEmpty {
                    targetTitle = title
                }
            }
            return ActivityEvent(
                eventID: id,
                tsMs: ts,
                signalType: signalType,
                bundleID: bundleID,
                eventKind: eventKind,
                bodyExcerpt: bodyExcerpt,
                bodyTruncated: bodyTruncated,
                targetRef: targetRef,
                targetTitle: targetTitle
            )
        }
        // Capture-side duplicate collapse (2026-06-11): the Linear boundary
        // re-fetch bug wrote dozens of identical rows per issue (same kind /
        // target / ts, different ids). New writes are guarded in the
        // collector; this protects responses over already-polluted DBs —
        // without it duplicates eat the entire 200-event projection budget.
        // Identical (event_kind, targetRef, ts) = the same logical update;
        // first row (newest id) wins. Events without a structured target
        // pass through untouched.
        var seenKeys = Set<String>()
        return projected.filter { e in
            guard let ref = e.targetRef, let kind = e.eventKind else { return true }
            let key = "\(kind)|\(ref)|\(e.tsMs)"
            return seenKeys.insert(key).inserted
        }
    }

    /// Used as fallback if a decision's originating event was retention-pruned
    /// (decisions hold their own `reasoning_excerpt`, so the response stays
    /// useful even with a placeholder event projection).
    private static func placeholderEvent(eventID: Int64) -> ActivityEvent {
        ActivityEvent(
            eventID: eventID, tsMs: 0, signalType: "unknown",
            bundleID: nil, eventKind: nil, bodyExcerpt: nil, bodyTruncated: false
        )
    }

    private func fetchDecisionsForResponse(
        eventIDs: [Int64], period: PeriodSpec, in db: GRDB.Database
    ) throws -> [DecisionView] {
        if eventIDs.isEmpty {
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, event_id, topic_keywords_json, reasoning_excerpt,
                       confidence, detected_at_ms
                  FROM decisions
                 WHERE detected_at_ms BETWEEN ? AND ?
                 ORDER BY detected_at_ms DESC
            """, arguments: [period.startMs, period.endMs])
            return rows.map(Self.decisionView(from:))
        }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
        let args: [DatabaseValueConvertible] = eventIDs.map { $0 } + [period.startMs, period.endMs]
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, topic_keywords_json, reasoning_excerpt,
                   confidence, detected_at_ms
              FROM decisions
             WHERE event_id IN (\(placeholders))
                OR detected_at_ms BETWEEN ? AND ?
             ORDER BY detected_at_ms DESC
        """, arguments: StatementArguments(args))
        return rows.map(Self.decisionView(from:))
    }

    private func fetchOpenQuestionsForResponse(
        eventIDs: [Int64], period: PeriodSpec, in db: GRDB.Database
    ) throws -> [OpenQuestionView] {
        if eventIDs.isEmpty {
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, event_id, question_excerpt, alternatives_json,
                       slack_thread_ts, linear_issue_ref, github_pr_ref,
                       resolved_by_event_id, opened_at_ms, resolved_at_ms
                  FROM open_questions
                 WHERE opened_at_ms BETWEEN ? AND ?
                 ORDER BY opened_at_ms DESC
            """, arguments: [period.startMs, period.endMs])
            return rows.map(Self.openQuestionView(from:))
        }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
        let args: [DatabaseValueConvertible] = eventIDs.map { $0 } + [period.startMs, period.endMs]
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, event_id, question_excerpt, alternatives_json,
                   slack_thread_ts, linear_issue_ref, github_pr_ref,
                   resolved_by_event_id, opened_at_ms, resolved_at_ms
              FROM open_questions
             WHERE event_id IN (\(placeholders))
                OR opened_at_ms BETWEEN ? AND ?
             ORDER BY opened_at_ms DESC
        """, arguments: StatementArguments(args))
        return rows.map(Self.openQuestionView(from:))
    }

    private func fetchBlockersForResponse(
        period: PeriodSpec, in db: GRDB.Database
    ) throws -> [BlockerView] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, target_kind, target_ref, blocker_kind, blocker_excerpt,
                   detected_by_event_id, started_at_ms, resolved_at_ms,
                   resolved_by_event_id
              FROM blockers
             WHERE started_at_ms BETWEEN ? AND ?
                OR (resolved_at_ms IS NOT NULL AND resolved_at_ms BETWEEN ? AND ?)
             ORDER BY started_at_ms DESC
        """, arguments: [period.startMs, period.endMs, period.startMs, period.endMs])
        return rows.map(Self.blockerView(from:))
    }

    private func fetchLinksForResponse(
        eventIDs: [Int64], in db: GRDB.Database
    ) throws -> [LinkView] {
        guard !eventIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT from_event_id, link_kind, target_kind, target_ref, confidence
              FROM event_links
             WHERE from_event_id IN (\(placeholders))
        """, arguments: StatementArguments(eventIDs))
        return rows.map { row in
            LinkView(
                fromEventID: row["from_event_id"],
                linkKind: row["link_kind"],
                targetKind: row["target_kind"],
                targetRef: row["target_ref"],
                confidence: row["confidence"]
            )
        }
    }

    // MARK: - Absence flags

    /// For each PR-event with `requested_reviewers_json`, fetches the linked
    /// Slack thread events and their Slack user identifiers, then runs each
    /// reviewer through `detectorMoat.absence.match`. Reviewers without a
    /// confident match → AbsenceFlag with most recent thread activity ts.
    private func computeAbsenceFlags(
        events: [ActivityEvent], in db: GRDB.Database
    ) throws -> [AbsenceFlag] {
        var out: [AbsenceFlag] = []
        for ev in events where (ev.eventKind ?? "").hasPrefix("gh_pr_") {
            // Re-fetch payload — `ActivityEvent` doesn't carry the structured
            // reviewer list (only excerpt). Cheap because we already have id.
            guard let payload = try fetchPayload(eventID: ev.eventID, in: db) else { continue }
            let reviewers: [String]
            if let raw = payload[Schema.EventPayloadKeys.requestedReviewersJson] as? String,
               let data = raw.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                reviewers = arr
            } else if let arr = payload[Schema.EventPayloadKeys.requestedReviewersJson] as? [String] {
                // Tolerate already-decoded array form (test fixtures may insert it raw).
                reviewers = arr
            } else {
                continue
            }
            guard !reviewers.isEmpty else { continue }
            guard let prRef = (payload["linked_github_pr"] as? String).flatMap({ $0.isEmpty ? nil : $0 })
            else { continue }

            // Linked Slack thread events for this PR (via reverse link lookup).
            let threadEventIDs = try EventLinksStore.eventsLinkingTo(
                targetKind: Schema.TargetKinds.githubPR,
                targetRef: prRef,
                period: nil,
                in: db
            )
            let slackIdentifiers = try collectSlackIdentifiers(eventIDs: threadEventIDs, in: db)
            let lastActivityMs: Int64
            if threadEventIDs.isEmpty {
                lastActivityMs = ev.tsMs
            } else {
                let placeholders = Array(repeating: "?", count: threadEventIDs.count).joined(separator: ",")
                lastActivityMs = (try Int64.fetchOne(db, sql: """
                    SELECT MAX(ts) FROM events WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(threadEventIDs))) ?? ev.tsMs
            }

            for login in reviewers {
                if detectorMoat.absence.match(
                    githubLogin: login, slackIdentifiers: slackIdentifiers
                ) == nil {
                    out.append(AbsenceFlag(
                        prRef: prRef,
                        reviewerLogin: login,
                        designChoiceExcerpt: ev.bodyExcerpt ?? "",
                        lastThreadActivityMs: lastActivityMs
                    ))
                }
            }
        }
        return out
    }

    /// Pulls SlackIdentifier values from the payload of each event id given.
    /// Slack collectors emit user_id / display_name / real_name on attention +
    /// attention-adjacent events; tests may seed them on any signal type.
    private func collectSlackIdentifiers(
        eventIDs: [Int64], in db: GRDB.Database
    ) throws -> [SlackIdentifier] {
        guard !eventIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT payload_json FROM events WHERE id IN (\(placeholders))
        """, arguments: StatementArguments(eventIDs))
        var out: [SlackIdentifier] = []
        for row in rows {
            let raw: String = (row["payload_json"] as String?) ?? "{}"
            guard let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let userID = dict["user_id"] as? String, !userID.isEmpty {
                out.append(SlackIdentifier(
                    userID: userID,
                    displayName: dict["display_name"] as? String,
                    realName: dict["real_name"] as? String
                ))
            }
        }
        return out
    }

    private func fetchPayload(eventID: Int64, in db: GRDB.Database) throws -> [String: Any]? {
        guard let raw = try String.fetchOne(db, sql: """
            SELECT payload_json FROM events WHERE id = ?
        """, arguments: [eventID]) else { return nil }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Byte budget

    /// Drops oldest event(s) from `events[]` until the encoded response fits
    /// within `byteBudget`. Records a `truncationNote` whenever any trim
    /// happens (including the edge case where 0 events still over-budget —
    /// caller still gets the structured response with returnedCount=0).
    private func enforceByteBudget(
        _ response: QueryActivityResponse, originalEventCount: Int
    ) throws -> QueryActivityResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(response)
        if data.count <= Self.byteBudget { return response }

        // events[] are ts DESC (newest first). removeLast() drops the oldest.
        var events = response.events
        while data.count > Self.byteBudget, !events.isEmpty {
            events.removeLast()
            let trimmed = QueryActivityResponse(
                period: response.period,
                filter: response.filter,
                events: events,
                decisionsInPeriod: response.decisionsInPeriod,
                openQuestions: response.openQuestions,
                blockers: response.blockers,
                links: response.links,
                absenceFlags: response.absenceFlags,
                truncationNote: TruncationNote(
                    reason: "byte_budget",
                    originalCount: originalEventCount,
                    returnedCount: events.count,
                    oldestReturnedTsMs: events.last?.tsMs
                )
            )
            data = try encoder.encode(trimmed)
            if data.count <= Self.byteBudget { return trimmed }
        }

        // Edge case — even with 0 events the response is still over-budget.
        // Surface the truncation_note so callers know they got a degraded response.
        return QueryActivityResponse(
            period: response.period,
            filter: response.filter,
            events: [],
            decisionsInPeriod: response.decisionsInPeriod,
            openQuestions: response.openQuestions,
            blockers: response.blockers,
            links: response.links,
            absenceFlags: response.absenceFlags,
            truncationNote: TruncationNote(
                reason: "byte_budget",
                originalCount: originalEventCount,
                returnedCount: 0,
                oldestReturnedTsMs: nil
            )
        )
    }

    // MARK: - Row → View mappers

    private static func decisionView(from row: Row) -> DecisionView {
        let topicJSON: String? = row["topic_keywords_json"] as String?
        let keywords: [String]
        if let topicJSON, let data = topicJSON.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            keywords = arr
        } else {
            keywords = []
        }
        return DecisionView(
            id: row["id"],
            eventID: row["event_id"],
            topicKeywords: keywords,
            reasoningExcerpt: row["reasoning_excerpt"],
            confidence: row["confidence"],
            detectedAtMs: row["detected_at_ms"]
        )
    }

    private static func openQuestionView(from row: Row) -> OpenQuestionView {
        let altsJSON: String? = row["alternatives_json"] as String?
        let alternatives: [String]?
        if let altsJSON, let data = altsJSON.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            alternatives = arr
        } else {
            alternatives = nil
        }
        return OpenQuestionView(
            id: row["id"],
            eventID: row["event_id"],
            questionExcerpt: row["question_excerpt"],
            alternatives: alternatives,
            slackThreadTS: row["slack_thread_ts"] as String?,
            linearIssueRef: row["linear_issue_ref"] as String?,
            githubPRRef: row["github_pr_ref"] as String?,
            resolvedByEventID: row["resolved_by_event_id"] as Int64?,
            openedAtMs: row["opened_at_ms"],
            resolvedAtMs: row["resolved_at_ms"] as Int64?
        )
    }

    private static func blockerView(from row: Row) -> BlockerView {
        BlockerView(
            id: row["id"],
            targetKind: row["target_kind"],
            targetRef: row["target_ref"],
            blockerKind: row["blocker_kind"],
            blockerExcerpt: row["blocker_excerpt"] as String?,
            detectedByEventID: row["detected_by_event_id"] as Int64?,
            startedAtMs: row["started_at_ms"],
            resolvedAtMs: row["resolved_at_ms"] as Int64?,
            resolvedByEventID: row["resolved_by_event_id"] as Int64?
        )
    }

    private func decisionView(from row: Row) -> DecisionView {
        Self.decisionView(from: row)
    }
}

// MARK: - LinkView <- EventLink

extension LinkView {
    /// Convenience init for translating the public substrate `EventLink`
    /// (carries `createdAtMs`) into the response-side `LinkView` (drops it).
    public init(from link: EventLink) {
        self.init(
            fromEventID: link.fromEventID,
            linkKind: link.linkKind,
            targetKind: link.targetKind,
            targetRef: link.targetRef,
            confidence: link.confidence
        )
    }
}
