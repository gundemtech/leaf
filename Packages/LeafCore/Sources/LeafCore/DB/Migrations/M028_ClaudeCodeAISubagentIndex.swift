import Foundation
import GRDB

/// Track-6 P1 — partial expression index on `events.payload_json.$.agent_id`
/// для subagent rollup queries. AI-rows only (per `WHERE signal_type
/// = 'aiCollaboration'`) — keeps the index narrow even on large events tables.
///
/// Numbering: M028 — renamed from M024 because Track-5/S5/S7 broadcast
/// offsets occupy slot M024 on the integration-T10 branch. Original Track-6 P1
/// shipped as M024 on `feature/track-10-operational-home`.
extension DatabaseMigrator {
  public mutating func registerMigration028ClaudeCodeAISubagentIndex() {
    registerMigration("028_claude_code_ai_subagent_index") { db in
      try db.execute(
        sql: """
              CREATE INDEX IF NOT EXISTS idx_events_ai_subagent
              ON events(json_extract(payload_json, '$.agent_id'))
              WHERE signal_type = 'aiCollaboration';
          """)
    }
  }
}
