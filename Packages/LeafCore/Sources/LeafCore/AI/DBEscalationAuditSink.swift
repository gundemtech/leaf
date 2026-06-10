import Foundation

/// Prod escalation audit sink: opens a brief `openForWrite` handle and appends
/// ONE row (ADR-019 departure — MCPServer is otherwise a reader; supported by WAL
/// + cross-process POSIX locks). Audit-first ordering is enforced by
/// `AIDetailAnswerer` (the writer fails → the send aborts).
///
/// AI-UI-2: promoted из LeafMCP в LeafCore — тот же sink используют MCP-тул
/// `escalate_to_ai` и in-app `EscalationReader` (прецедент app-записи —
/// `HandoffAuditWriter`).
public struct DBEscalationAuditSink: AuditSink {
  let dbURL: URL
  let dbConfig: DatabaseConfig
  let dbEncryption: EncryptionOptions?

  public init(dbURL: URL, dbConfig: DatabaseConfig, dbEncryption: EncryptionOptions?) {
    self.dbURL = dbURL
    self.dbConfig = dbConfig
    self.dbEncryption = dbEncryption
  }

  public func record(_ entry: EscalationAuditEntry) async throws {
    let db = try Database.openForWrite(at: dbURL, config: dbConfig, encryption: dbEncryption)
    try db.appendAIEscalationAudit(
      generatedAtMs: entry.occurredAtMs,
      questionExcerpt: entry.question,
      model: entry.model,
      eventIDs: entry.eventIDs,
      sourceSummary: entry.sourceSummary)
  }
}
