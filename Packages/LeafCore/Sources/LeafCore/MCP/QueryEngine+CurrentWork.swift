//
//  QueryEngine+CurrentWork.swift
//  LeafCore
//
//  Extension split (Phase 2.3.C.4) — `currentWork` + 8 projection helpers
//  for the `leaf_current_work` MCP tool. Pure relocation from QueryEngine.swift.
//

import Foundation
import GRDB

extension QueryEngine {
    // MARK: - currentWork

    public func currentWork(nowMs: Int64) throws -> CurrentWorkResponse {
        let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
        return try db.readSQL { rawDB -> CurrentWorkResponse in
            CurrentWorkResponse(
                currentApp: try Self.fetchCurrentApp(in: rawDB),
                currentBranch: try Self.fetchCurrentBranch(in: rawDB),
                currentFile: try Self.fetchCurrentFile(in: rawDB),
                inProgressLinearTicket: try Self.fetchInProgressLinearTicket(in: rawDB),
                lastCommit: try Self.fetchLastCommit(in: rawDB),
                currentOpenQuestions: try Self.fetchCurrentOpenQuestions(in: rawDB),
                currentBlockers: try Self.fetchCurrentBlockers(in: rawDB),
                whereStopped: try Self.fetchWhereStopped(nowMs: nowMs, in: rawDB)
            )
        }
    }

    // MARK: - currentWork projection helpers

    /// current_app: latest attention-signal event.
    static func fetchCurrentApp(in db: GRDB.Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
                    SELECT bundle_id FROM events
                     WHERE signal_type = 'attention' AND bundle_id IS NOT NULL
                     ORDER BY ts DESC LIMIT 1
                """)
    }

    /// current_branch: latest gh_commit_pushed payload.branch.
    static func fetchCurrentBranch(in db: GRDB.Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
                    SELECT json_extract(payload_json, '$.branch') FROM events
                     WHERE json_extract(payload_json, '$.event_kind') = 'gh_commit_pushed'
                       AND json_extract(payload_json, '$.branch') IS NOT NULL
                     ORDER BY ts DESC LIMIT 1
                """)
    }

    /// current_file: latest attention event with non-empty window_title
    /// (collectors emit window_title onto attention payloads — see
    /// `AttentionEmissionPlanner`; there is no separate `ax_window` signal
    /// type in substrate).
    static func fetchCurrentFile(in db: GRDB.Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
                    SELECT json_extract(payload_json, '$.window_title') FROM events
                     WHERE signal_type = 'attention'
                       AND json_extract(payload_json, '$.window_title') IS NOT NULL
                       AND json_extract(payload_json, '$.window_title') != ''
                     ORDER BY ts DESC LIMIT 1
                """)
    }

    /// in_progress_linear_ticket: latest issue_updated whose status != 'Done'.
    /// Linear collector emits payload.event_kind = "issue_updated" + payload.status.
    static func fetchInProgressLinearTicket(in db: GRDB.Database) throws -> LinearTicketRef? {
        try Row.fetchOne(
            db,
            sql: """
                    SELECT json_extract(payload_json, '$.issue_key')   AS issue_ref,
                           json_extract(payload_json, '$.title')       AS title,
                           json_extract(payload_json, '$.status')      AS status
                      FROM events
                     WHERE json_extract(payload_json, '$.event_kind') = 'issue_updated'
                       AND COALESCE(json_extract(payload_json, '$.status'), '') != 'Done'
                       AND json_extract(payload_json, '$.issue_key') IS NOT NULL
                     ORDER BY ts DESC LIMIT 1
                """
        ).flatMap { row -> LinearTicketRef? in
            guard let ref: String = row["issue_ref"] else { return nil }
            return LinearTicketRef(
                issueRef: ref,
                title: row["title"] as String?,
                stateName: row["status"] as String?
            )
        }
    }

    /// last_commit: latest gh_commit_pushed projection.
    static func fetchLastCommit(in db: GRDB.Database) throws -> CommitRef? {
        try Row.fetchOne(
            db,
            sql: """
                    SELECT ts,
                           json_extract(payload_json, '$.sha')     AS sha,
                           json_extract(payload_json, '$.body')    AS message,
                           json_extract(payload_json, '$.branch')  AS branch
                      FROM events
                     WHERE json_extract(payload_json, '$.event_kind') = 'gh_commit_pushed'
                     ORDER BY ts DESC LIMIT 1
                """
        ).map { row in
            CommitRef(
                sha: row["sha"] as String?,
                message: row["message"] as String?,
                branch: row["branch"] as String?,
                pushedAtMs: row["ts"] as Int64?
            )
        }
    }

    /// current_open_questions: limit 20, unresolved.
    static func fetchCurrentOpenQuestions(in db: GRDB.Database) throws -> [OpenQuestionView] {
        try Row.fetchAll(
            db,
            sql: """
                    SELECT id, event_id, question_excerpt, alternatives_json,
                           slack_thread_ts, linear_issue_ref, github_pr_ref,
                           resolved_by_event_id, opened_at_ms, resolved_at_ms
                      FROM open_questions
                     WHERE resolved_at_ms IS NULL
                     ORDER BY opened_at_ms DESC LIMIT 20
                """
        ).map(Self.openQuestionView(from:))
    }

    /// current_blockers: limit 10, unresolved.
    static func fetchCurrentBlockers(in db: GRDB.Database) throws -> [BlockerView] {
        try Row.fetchAll(
            db,
            sql: """
                    SELECT id, target_kind, target_ref, blocker_kind, blocker_excerpt,
                           detected_by_event_id, started_at_ms, resolved_at_ms,
                           resolved_by_event_id
                      FROM blockers
                     WHERE resolved_at_ms IS NULL
                     ORDER BY started_at_ms DESC LIMIT 10
                """
        ).map(Self.blockerView(from:))
    }

    /// where_stopped: latest where_stopped_log row IF generated within the
    /// last 24h (older snapshots are stale for "current work").
    static func fetchWhereStopped(nowMs: Int64, in db: GRDB.Database) throws -> WhereStoppedOutput? {
        guard let row = try WhereStoppedLogStore.latest(in: db),
            let generatedAtMs: Int64 = row["generated_at_ms"]
        else { return nil }
        guard nowMs - generatedAtMs <= Self.whereStoppedFreshnessWindowMs else { return nil }
        let excerpt: String = (row["excerpt"] as String?) ?? ""
        let anchor: Int64? = row["anchor_event_id"] as Int64?
        let wipJSON: String? = row["wip_signals_json"] as String?
        let wip: WipSignals
        if let wipJSON, let data = wipJSON.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(WipSignals.self, from: data)
        {
            wip = decoded
        } else {
            wip = WipSignals(commitWip: false, ciFailing: false, midEdit: false)
        }
        return WhereStoppedOutput(excerpt: excerpt, wipSignals: wip, anchorEventID: anchor)
    }
}
