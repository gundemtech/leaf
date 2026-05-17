//
//  QueryEngine+Projection.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.4) — projection helpers + row→view mappers.
//  Pure relocation from QueryEngine.swift.
//

import Foundation
import GRDB

extension QueryEngine {
    // MARK: - Projection helpers

    /// Decode events by id list → slim ActivityEvent. Returns events ordered ts DESC.
    /// (Caller order is not preserved — we re-sort after fetch so byte-budget
    /// trim discipline ("oldest-last") works regardless of input order.)
    func projectEvents(eventIDs: [Int64], in db: GRDB.Database) throws -> [ActivityEvent] {
        guard !eventIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: eventIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: """
                    SELECT id, ts, signal_type, bundle_id, payload_json
                      FROM events WHERE id IN (\(placeholders))
                      ORDER BY ts DESC
                """, arguments: StatementArguments(eventIDs))
        return rows.map { row -> ActivityEvent in
            let id: Int64 = row["id"]
            let ts: Int64 = row["ts"]
            let signalType: String = row["signal_type"]
            let bundleID: String? = row["bundle_id"] as String?
            let payloadJSON: String = (row["payload_json"] as String?) ?? "{}"

            var eventKind: String?
            var bodyExcerpt: String?
            var bodyTruncated = false
            if let data = payloadJSON.data(using: .utf8),
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                eventKind = dict["event_kind"] as? String
                if let body = dict[Schema.EventPayloadKeys.body] as? String, !body.isEmpty {
                    let (excerpt, truncated) = BodyExcerpt.capped(body, charCap: bodyExcerptCharCap)
                    bodyExcerpt = excerpt
                    bodyTruncated = truncated
                }
            }
            return ActivityEvent(
                eventID: id,
                tsMs: ts,
                signalType: signalType,
                bundleID: bundleID,
                eventKind: eventKind,
                bodyExcerpt: bodyExcerpt,
                bodyTruncated: bodyTruncated
            )
        }
    }

    /// Used as fallback if a decision's originating event was retention-pruned
    /// (decisions hold their own `reasoning_excerpt`, so the response stays
    /// useful even with a placeholder event projection).
    static func placeholderEvent(eventID: Int64) -> ActivityEvent {
        ActivityEvent(
            eventID: eventID, tsMs: 0, signalType: "unknown",
            bundleID: nil, eventKind: nil, bodyExcerpt: nil, bodyTruncated: false
        )
    }

    // MARK: - Row → View mappers

    static func decisionView(from row: Row) -> DecisionView {
        let topicJSON: String? = row["topic_keywords_json"] as String?
        let keywords: [String]
        if let topicJSON, let data = topicJSON.data(using: .utf8),
            let arr = try? JSONDecoder().decode([String].self, from: data)
        {
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

    static func openQuestionView(from row: Row) -> OpenQuestionView {
        let altsJSON: String? = row["alternatives_json"] as String?
        let alternatives: [String]?
        if let altsJSON, let data = altsJSON.data(using: .utf8),
            let arr = try? JSONDecoder().decode([String].self, from: data)
        {
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

    static func blockerView(from row: Row) -> BlockerView {
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

    func decisionView(from row: Row) -> DecisionView {
        Self.decisionView(from: row)
    }
}
