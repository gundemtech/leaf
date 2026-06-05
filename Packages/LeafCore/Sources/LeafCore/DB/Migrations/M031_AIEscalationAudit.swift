import Foundation
import GRDB

/// Phase AI Coworker P3 — `ai_escalation_audit`, the append-only reverse audit
/// of every cloud escalation the headless `escalate_to_ai` MCP tool performs
/// (§8 п.4 "every escalation is audited"; canon §13.4). Written audit-first,
/// BEFORE the outbound LLM POST — over-record, never under-record (an aborted
/// POST still leaves a row; a successful POST is never unaudited).
///
/// Append-only by convention — the writer (`AIEscalationAuditStore`) exposes
/// INSERT only; no UPDATE/DELETE path (mirrors `where_stopped_log`, M014). The
/// audit records *what* was escalated, never the body text: `question_excerpt`
/// = the user's OWN question, `event_ids_json` = `events.id` refs, `source_summary`
/// = counts+kinds. The single index on `generated_at_ms` serves the read-back
/// tool's `ORDER BY generated_at_ms DESC LIMIT ?`.
extension DatabaseMigrator {
    public mutating func registerMigration031AIEscalationAudit() {
        registerMigration("031_ai_escalation_audit") { db in
            try db.create(table: Schema.AIEscalationAudit.tableName, ifNotExists: true) { t in
                t.column(Schema.AIEscalationAudit.id, .integer).primaryKey(autoincrement: true)
                t.column(Schema.AIEscalationAudit.generatedAtMs, .integer).notNull()
                t.column(Schema.AIEscalationAudit.questionExcerpt, .text)
                t.column(Schema.AIEscalationAudit.model, .text).notNull()
                t.column(Schema.AIEscalationAudit.eventIDsJSON, .text).notNull()
                t.column(Schema.AIEscalationAudit.sourceSummary, .text).notNull()
            }
            try db.execute(
                sql: """
                    CREATE INDEX IF NOT EXISTS \(Schema.AIEscalationAudit.indexGeneratedAt)
                      ON \(Schema.AIEscalationAudit.tableName)(\(Schema.AIEscalationAudit.generatedAtMs))
                    """)
        }
    }
}
