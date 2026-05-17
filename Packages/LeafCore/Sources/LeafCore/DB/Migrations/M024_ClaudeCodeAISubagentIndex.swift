import Foundation
import GRDB

/// Track-6 P1 — partial expression index on `events.payload_json.$.agent_id`
/// для subagent rollup queries Phase 4.9. AI-rows only (per `WHERE signal_type
/// = 'aiCollaboration'`) — keeps the index narrow even on large events tables.
///
/// Numbering: M024 leaves M019-M023 reserved for the Track-5 collaboration
/// redesign stack which is in flight on a separate branch.
extension DatabaseMigrator {
    public mutating func registerMigration024ClaudeCodeAISubagentIndex() {
        registerMigration("024_claude_code_ai_subagent_index") { db in
            try db.execute(
                sql: """
                        CREATE INDEX IF NOT EXISTS idx_events_ai_subagent
                        ON events(json_extract(payload_json, '$.agent_id'))
                        WHERE signal_type = 'aiCollaboration';
                    """)
        }
    }
}
