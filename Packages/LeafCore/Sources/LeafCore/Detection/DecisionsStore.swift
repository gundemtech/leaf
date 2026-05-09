import Foundation
import GRDB

/// Phase Track-1 D3 — `decisions` writer.
///
/// `event_id` is UNIQUE — INSERT OR IGNORE gives per-event idempotency on
/// backfill / re-run after cursor reset. Returns whether a row was actually
/// inserted (callsite uses this to enforce one-decision-per-event).
public enum DecisionsStore {
    public static func insertOrIgnore(eventID: Int64,
                                      hit: DecisionHit,
                                      detectedAtMs: Int64,
                                      in db: GRDB.Database) throws -> Bool {
        let topicJSON: String
        if let data = try? JSONEncoder().encode(hit.topicKeywords),
           let s = String(data: data, encoding: .utf8) {
            topicJSON = s
        } else {
            topicJSON = "[]"
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO decisions
                (event_id, topic_keywords_json, reasoning_excerpt, confidence, detected_at_ms)
            VALUES (?, ?, ?, ?, ?)
        """, arguments: [eventID, topicJSON, hit.reasoningExcerpt,
                         hit.confidence, detectedAtMs])
        return db.changesCount > 0
    }
}
