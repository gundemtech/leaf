import Foundation
import GRDB

/// Phase Track-1 D3 — row carrier for an `open_questions` insert.
public struct OpenQuestionRow: Sendable {
    public let eventID: Int64
    public let hit: OpenQuestionHit
    public let slackThreadTS: String?
    public let linearIssueRef: String?
    public let githubPRRef: String?
    public let openedAtMs: Int64

    public init(eventID: Int64,
                hit: OpenQuestionHit,
                slackThreadTS: String?,
                linearIssueRef: String?,
                githubPRRef: String?,
                openedAtMs: Int64) {
        self.eventID = eventID
        self.hit = hit
        self.slackThreadTS = slackThreadTS
        self.linearIssueRef = linearIssueRef
        self.githubPRRef = githubPRRef
        self.openedAtMs = openedAtMs
    }
}

/// Resolution context for a candidate "answer" event. At least one populated
/// field is required for `markResolved` to issue an UPDATE — the partial
/// indexes on `open_questions` (slack/linear/pr) bound the scan per branch.
public struct ResolutionContexts: Sendable {
    public let slackThreadTS: String?
    public let linearIssueRefs: [String]
    public let githubPRRefs: [String]

    public init(slackThreadTS: String?,
                linearIssueRefs: [String],
                githubPRRefs: [String]) {
        self.slackThreadTS = slackThreadTS
        self.linearIssueRefs = linearIssueRefs
        self.githubPRRefs = githubPRRefs
    }
}

public enum OpenQuestionsStore {
    public static func insertOrIgnore(_ row: OpenQuestionRow,
                                      in db: GRDB.Database) throws -> Bool {
        let altsJSON: String?
        if let alts = row.hit.alternatives,
           let data = try? JSONEncoder().encode(alts),
           let s = String(data: data, encoding: .utf8) {
            altsJSON = s
        } else {
            altsJSON = nil
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO open_questions
                (event_id, question_excerpt, alternatives_json,
                 slack_thread_ts, linear_issue_ref, github_pr_ref,
                 opened_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, arguments: [row.eventID, row.hit.questionExcerpt, altsJSON,
                         row.slackThreadTS, row.linearIssueRef, row.githubPRRef,
                         row.openedAtMs])
        return db.changesCount > 0
    }

    /// Resolves all unresolved open_questions whose context overlaps `contexts`.
    /// Builds the WHERE OR-clauses dynamically so that empty context fields
    /// don't degrade to a full-table scan via NULL = NULL semantics. Returns
    /// rows affected.
    public static func markResolved(matchingContexts contexts: ResolutionContexts,
                                    resolvedByEventID: Int64,
                                    resolvedAtMs: Int64,
                                    in db: GRDB.Database) throws -> Int {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if let ts = contexts.slackThreadTS {
            clauses.append("slack_thread_ts = ?")
            args.append(ts)
        }
        if !contexts.linearIssueRefs.isEmpty {
            let qs = String(repeating: "?, ", count: contexts.linearIssueRefs.count).dropLast(2)
            clauses.append("linear_issue_ref IN (\(qs))")
            args.append(contentsOf: contexts.linearIssueRefs.map { $0 as DatabaseValueConvertible? })
        }
        if !contexts.githubPRRefs.isEmpty {
            let qs = String(repeating: "?, ", count: contexts.githubPRRefs.count).dropLast(2)
            clauses.append("github_pr_ref IN (\(qs))")
            args.append(contentsOf: contexts.githubPRRefs.map { $0 as DatabaseValueConvertible? })
        }
        guard !clauses.isEmpty else { return 0 }

        let sql = """
            UPDATE open_questions
               SET resolved_by_event_id = ?, resolved_at_ms = ?
             WHERE resolved_at_ms IS NULL AND (\(clauses.joined(separator: " OR ")))
        """
        let head: [DatabaseValueConvertible?] = [resolvedByEventID, resolvedAtMs]
        try db.execute(sql: sql, arguments: StatementArguments(head + args))
        return db.changesCount
    }
}
