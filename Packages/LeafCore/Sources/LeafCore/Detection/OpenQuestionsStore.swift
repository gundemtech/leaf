import Foundation
import GRDB

/// Phase Track-1 D3 — INSERT-side carrier for `open_questions` rows.
/// Resolution flow (UPDATE on `resolved_by_event_id` / `resolved_at_ms`)
/// lives in the next commit — this store ships only the insert path.
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
}
