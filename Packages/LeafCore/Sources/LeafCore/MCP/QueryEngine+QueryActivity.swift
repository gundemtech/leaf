//
//  QueryEngine+QueryActivity.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.4) — `queryActivity` + per-response fetchers
//  + absence-flag computation + byte-budget enforcement. Pure relocation
//  from QueryEngine.swift.
//

import Foundation
import GRDB

extension QueryEngine {
    // MARK: - queryActivity

    public func queryActivity(
        period: PeriodSpec,
        filter: String?
    ) throws -> QueryActivityResponse {
        let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        return try db.readSQL { rawDB -> QueryActivityResponse in
            // 1. Event-id set: FTS branch when filter present + non-empty,
            //    fallback to recent-events SELECT otherwise.
            let eventIDs: [Int64]
            if let filter, !filter.trimmingCharacters(in: .whitespaces).isEmpty {
                eventIDs = try EventsFullTextStore.search(
                    query: filter,
                    period: period.startMs...period.endMs,
                    limit: Self.sqlEventLimit,
                    in: rawDB
                )
            } else {
                eventIDs = try Int64.fetchAll(
                    rawDB,
                    sql: """
                            SELECT id FROM events
                             WHERE ts BETWEEN ? AND ?
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

    // MARK: - Per-response fetchers

    func fetchDecisionsForResponse(
        eventIDs: [Int64], period: PeriodSpec, in db: GRDB.Database
    ) throws -> [DecisionView] {
        if eventIDs.isEmpty {
            let rows = try Row.fetchAll(
                db,
                sql: """
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
        let rows = try Row.fetchAll(
            db,
            sql: """
                    SELECT id, event_id, topic_keywords_json, reasoning_excerpt,
                           confidence, detected_at_ms
                      FROM decisions
                     WHERE event_id IN (\(placeholders))
                        OR detected_at_ms BETWEEN ? AND ?
                     ORDER BY detected_at_ms DESC
                """, arguments: StatementArguments(args))
        return rows.map(Self.decisionView(from:))
    }

    func fetchOpenQuestionsForResponse(
        eventIDs: [Int64], period: PeriodSpec, in db: GRDB.Database
    ) throws -> [OpenQuestionView] {
        if eventIDs.isEmpty {
            let rows = try Row.fetchAll(
                db,
                sql: """
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
        let rows = try Row.fetchAll(
            db,
            sql: """
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

    func fetchBlockersForResponse(
        period: PeriodSpec, in db: GRDB.Database
    ) throws -> [BlockerView] {
        let rows = try Row.fetchAll(
            db,
            sql: """
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

    func fetchLinksForResponse(
        eventIDs: [Int64], in db: GRDB.Database
    ) throws -> [LinkView] {
        guard !eventIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
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
    func computeAbsenceFlags(
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
                let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
            {
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
                lastActivityMs =
                    (try Int64.fetchOne(
                        db,
                        sql: """
                                SELECT MAX(ts) FROM events WHERE id IN (\(placeholders))
                            """, arguments: StatementArguments(threadEventIDs))) ?? ev.tsMs
            }

            for login in reviewers where detectorMoat.absence.match(
                githubLogin: login, slackIdentifiers: slackIdentifiers
            ) == nil {
                out.append(
                    AbsenceFlag(
                        prRef: prRef,
                        reviewerLogin: login,
                        designChoiceExcerpt: ev.bodyExcerpt ?? "",
                        lastThreadActivityMs: lastActivityMs
                    ))
            }
        }
        return out
    }

    /// Pulls SlackIdentifier values from the payload of each event id given.
    /// Slack collectors emit user_id / display_name / real_name on attention +
    /// attention-adjacent events; tests may seed them on any signal type.
    func collectSlackIdentifiers(
        eventIDs: [Int64], in db: GRDB.Database
    ) throws -> [SlackIdentifier] {
        guard !eventIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                    SELECT payload_json FROM events WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(eventIDs))
        var out: [SlackIdentifier] = []
        for row in rows {
            let raw: String = (row["payload_json"] as String?) ?? "{}"
            guard let data = raw.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let userID = dict["user_id"] as? String, !userID.isEmpty {
                out.append(
                    SlackIdentifier(
                        userID: userID,
                        displayName: dict["display_name"] as? String,
                        realName: dict["real_name"] as? String
                    ))
            }
        }
        return out
    }

    func fetchPayload(eventID: Int64, in db: GRDB.Database) throws -> [String: Any]? {
        guard
            let raw = try String.fetchOne(
                db,
                sql: """
                        SELECT payload_json FROM events WHERE id = ?
                    """, arguments: [eventID])
        else { return nil }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Byte budget

    /// Drops oldest event(s) from `events[]` until the encoded response fits
    /// within `byteBudget`. Records a `truncationNote` whenever any trim
    /// happens (including the edge case where 0 events still over-budget —
    /// caller still gets the structured response with returnedCount=0).
    func enforceByteBudget(
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
}
