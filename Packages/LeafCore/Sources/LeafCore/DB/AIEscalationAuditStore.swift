import Foundation
import GRDB

/// Phase AI Coworker P3 — append-only writer/reader for `ai_escalation_audit`
/// (M031). Append-only by convention (mirrors `WhereStoppedLogStore`): only
/// INSERT + SELECT are exposed; there is no UPDATE/DELETE path — the escalation
/// audit trail is immutable ("audit > соблазн", canon §13.4). Rows record WHAT
/// was escalated (event id refs + magnitudes + the user's own question), never
/// the body text.
public enum AIEscalationAuditStore {

  /// Decoded view of one audit row for the read-back tool (§13.4 "AI received").
  public struct AuditEntryView: Sendable, Equatable {
    public let id: Int64
    public let generatedAtMs: Int64
    public let questionExcerpt: String?
    public let model: String
    public let eventIDs: [Int64]
    public let sourceSummary: String

    public init(
      id: Int64, generatedAtMs: Int64, questionExcerpt: String?,
      model: String, eventIDs: [Int64], sourceSummary: String
    ) {
      self.id = id
      self.generatedAtMs = generatedAtMs
      self.questionExcerpt = questionExcerpt
      self.model = model
      self.eventIDs = eventIDs
      self.sourceSummary = sourceSummary
    }
  }

  /// INSERT one immutable audit row. `eventIDs` serialize to a compact JSON int
  /// array (`[Int64]` cannot fail to encode; fall back to "[]" defensively so a
  /// row is never lost). The row is structurally body-free — no parameter can
  /// carry body text.
  public static func append(
    generatedAtMs: Int64,
    questionExcerpt: String?,
    model: String,
    eventIDs: [Int64],
    sourceSummary: String,
    in db: GRDB.Database
  ) throws {
    let idsData = (try? JSONEncoder().encode(eventIDs)) ?? Data("[]".utf8)
    let idsJSON = String(data: idsData, encoding: .utf8) ?? "[]"
    try db.execute(
      sql: """
        INSERT INTO \(Schema.AIEscalationAudit.tableName) (
            \(Schema.AIEscalationAudit.generatedAtMs),
            \(Schema.AIEscalationAudit.questionExcerpt),
            \(Schema.AIEscalationAudit.model),
            \(Schema.AIEscalationAudit.eventIDsJSON),
            \(Schema.AIEscalationAudit.sourceSummary)
        ) VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [generatedAtMs, questionExcerpt, model, idsJSON, sourceSummary])
  }

  /// Most-recent `limit` rows, newest first (`generated_at_ms DESC`).
  public static func recent(limit: Int, in db: GRDB.Database) throws -> [AuditEntryView] {
    guard limit > 0 else { return [] }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT \(Schema.AIEscalationAudit.id),
               \(Schema.AIEscalationAudit.generatedAtMs),
               \(Schema.AIEscalationAudit.questionExcerpt),
               \(Schema.AIEscalationAudit.model),
               \(Schema.AIEscalationAudit.eventIDsJSON),
               \(Schema.AIEscalationAudit.sourceSummary)
          FROM \(Schema.AIEscalationAudit.tableName)
         ORDER BY \(Schema.AIEscalationAudit.generatedAtMs) DESC
         LIMIT ?
        """,
      arguments: [limit])
    return rows.compactMap { row in
      guard let id: Int64 = row[Schema.AIEscalationAudit.id],
        let gen: Int64 = row[Schema.AIEscalationAudit.generatedAtMs],
        let model: String = row[Schema.AIEscalationAudit.model],
        let summary: String = row[Schema.AIEscalationAudit.sourceSummary]
      else { return nil }
      let idsJSON = (row[Schema.AIEscalationAudit.eventIDsJSON] as String?) ?? "[]"
      let ids = (try? JSONDecoder().decode([Int64].self, from: Data(idsJSON.utf8))) ?? []
      return AuditEntryView(
        id: id, generatedAtMs: gen,
        questionExcerpt: row[Schema.AIEscalationAudit.questionExcerpt] as String?,
        model: model, eventIDs: ids, sourceSummary: summary)
    }
  }
}
