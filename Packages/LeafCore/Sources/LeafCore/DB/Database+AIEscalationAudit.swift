import Foundation
import GRDB

/// Phase AI Coworker P3 — public `Database` accessors over `AIEscalationAuditStore`
/// (mirrors `Database+InviteTokens`). Callers outside LeafCore tests use these
/// instead of the internal pool.
extension Database {

  /// Append one escalation audit row. Writer-mode only (`writeSQL` enforces the
  /// `mode == .writer` guard). The `escalate_to_ai` MCP tool opens a brief
  /// `openForWrite` handle specifically to call this BEFORE its outbound LLM POST
  /// — over-record, never under-record (§8 п.4). ADR-019 departure: MCPServer is
  /// otherwise a reader; this one write is justified by "every escalation is
  /// audited" and is supported by WAL + cross-process POSIX locks.
  public func appendAIEscalationAudit(
    generatedAtMs: Int64,
    questionExcerpt: String?,
    model: String,
    eventIDs: [Int64],
    sourceSummary: String
  ) throws {
    try writeSQL { db in
      try AIEscalationAuditStore.append(
        generatedAtMs: generatedAtMs, questionExcerpt: questionExcerpt,
        model: model, eventIDs: eventIDs, sourceSummary: sourceSummary, in: db)
    }
  }

  /// Recent escalation audit rows, newest first (read-back tool, §13.4). Reader-safe.
  public func recentAIEscalationAudit(limit: Int) throws -> [AIEscalationAuditStore.AuditEntryView] {
    try readSQL { db in try AIEscalationAuditStore.recent(limit: limit, in: db) }
  }
}
