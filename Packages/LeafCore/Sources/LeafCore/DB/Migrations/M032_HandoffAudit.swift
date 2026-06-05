import Foundation
import GRDB

/// Phase AI Coworker P4 — `handoff_audit`, the append-only reverse audit of every
/// AI-assisted team handoff the user approves + delivers E2E to a teammate (§8 п.4
/// "handoff visible + logged"; canon §6/§13.6). Written at SEND time — the
/// auditable team-egress is the E2E DM, not the discardable draft (the draft leg,
/// my-facts → my-LLM, goes through the same body-free `makeContext` boundary as
/// P1's default path, which is deliberately unaudited).
///
/// Append-only by convention — the writer (`HandoffAuditStore`) exposes INSERT
/// only; no UPDATE/DELETE path (mirrors `ai_escalation_audit`, M031, and
/// `where_stopped_log`, M014). The row records the AI *provenance* of the push,
/// never bodies and never the recipient pubkey: `recipient_member_id` =
/// TeamMember.id ref, `topic_excerpt` = the user's OWN normalized topic,
/// `source_summary` = counts+kinds, `crossposted_*` = whether the body also left
/// E2E to a third party (CR-1 accountability), `message_id` = soft-FK into
/// `messages_mirror`. The single index on `generated_at_ms` serves the read-back
/// tool's `ORDER BY generated_at_ms DESC LIMIT ?`.
extension DatabaseMigrator {
    public mutating func registerMigration032HandoffAudit() {
        registerMigration("032_handoff_audit") { db in
            try db.create(table: Schema.HandoffAudit.tableName, ifNotExists: true) { t in
                t.column(Schema.HandoffAudit.id, .integer).primaryKey(autoincrement: true)
                t.column(Schema.HandoffAudit.generatedAtMs, .integer).notNull()
                t.column(Schema.HandoffAudit.messageID, .text)
                t.column(Schema.HandoffAudit.recipientMemberID, .text)
                t.column(Schema.HandoffAudit.model, .text).notNull()
                t.column(Schema.HandoffAudit.path, .text).notNull()
                t.column(Schema.HandoffAudit.periodStartMs, .integer).notNull()
                t.column(Schema.HandoffAudit.periodEndMs, .integer).notNull()
                t.column(Schema.HandoffAudit.factCount, .integer).notNull()
                t.column(Schema.HandoffAudit.escalated, .integer).notNull().defaults(to: 0)
                t.column(Schema.HandoffAudit.crosspostedSlack, .integer).notNull().defaults(to: 0)
                t.column(Schema.HandoffAudit.crosspostedLinear, .integer).notNull().defaults(to: 0)
                t.column(Schema.HandoffAudit.sourceSummary, .text).notNull()
                t.column(Schema.HandoffAudit.topicExcerpt, .text)
            }
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS \(Schema.HandoffAudit.indexGeneratedAt)
                      ON \(Schema.HandoffAudit.tableName)(\(Schema.HandoffAudit.generatedAtMs))
                    """)
        }
    }
}
