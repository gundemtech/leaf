import Foundation
import GRDB

/// Phase AI Coworker P4 — public `Database` accessors over `HandoffAuditStore`
/// (mirrors `Database+AIEscalationAudit`). The app writes one row at SEND time
/// via a brief `openForWrite` handle (`HandoffAuditWriter`); the `get_handoff_log`
/// MCP tool reads them back.
extension Database {

  /// Append one handoff audit row. Writer-mode only (`writeSQL` enforces the
  /// `mode == .writer` guard). Called after an AI-assisted handoff DM is
  /// successfully sent (E2E) — the team-egress is the auditable act (§8 п.4).
  public func appendHandoffAudit(
    generatedAtMs: Int64,
    messageID: String?,
    recipientMemberID: String?,
    model: String,
    path: String,
    periodStartMs: Int64,
    periodEndMs: Int64,
    factCount: Int,
    escalated: Bool,
    crosspostedSlack: Bool,
    crosspostedLinear: Bool,
    sourceSummary: String,
    topicExcerpt: String?
  ) throws {
    try writeSQL { db in
      try HandoffAuditStore.append(
        generatedAtMs: generatedAtMs, messageID: messageID,
        recipientMemberID: recipientMemberID, model: model, path: path,
        periodStartMs: periodStartMs, periodEndMs: periodEndMs, factCount: factCount,
        escalated: escalated, crosspostedSlack: crosspostedSlack,
        crosspostedLinear: crosspostedLinear, sourceSummary: sourceSummary,
        topicExcerpt: topicExcerpt, in: db)
    }
  }

  /// Recent handoff audit rows, newest first (read-back tool). Reader-safe.
  public func recentHandoffAudit(limit: Int) throws -> [HandoffAuditStore.AuditEntryView] {
    try readSQL { db in try HandoffAuditStore.recent(limit: limit, in: db) }
  }
}
