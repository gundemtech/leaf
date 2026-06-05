import Foundation
import GRDB

/// Phase AI Coworker P4 — append-only writer/reader for `handoff_audit` (M032).
/// Append-only by convention (mirrors `AIEscalationAuditStore`): only INSERT +
/// SELECT are exposed; there is no UPDATE/DELETE path — the handoff audit trail
/// is immutable ("audit > соблазн", canon §13.4). Rows record the AI *provenance*
/// of a team handoff the user approved + sent (model, period, counts+kinds, the
/// user's own topic, whether it also cross-posted off E2E), never the body text
/// and never the recipient pubkey.
public enum HandoffAuditStore {

  /// Decoded view of one audit row for the read-back tool ("AI handoffs" feed).
  public struct AuditEntryView: Sendable, Equatable {
    public let id: Int64
    public let generatedAtMs: Int64
    public let messageID: String?
    public let recipientMemberID: String?
    public let model: String
    public let path: String
    public let periodStartMs: Int64
    public let periodEndMs: Int64
    public let factCount: Int
    public let escalated: Bool
    public let crosspostedSlack: Bool
    public let crosspostedLinear: Bool
    public let sourceSummary: String
    public let topicExcerpt: String?

    public init(
      id: Int64, generatedAtMs: Int64, messageID: String?, recipientMemberID: String?,
      model: String, path: String, periodStartMs: Int64, periodEndMs: Int64,
      factCount: Int, escalated: Bool, crosspostedSlack: Bool, crosspostedLinear: Bool,
      sourceSummary: String, topicExcerpt: String?
    ) {
      self.id = id
      self.generatedAtMs = generatedAtMs
      self.messageID = messageID
      self.recipientMemberID = recipientMemberID
      self.model = model
      self.path = path
      self.periodStartMs = periodStartMs
      self.periodEndMs = periodEndMs
      self.factCount = factCount
      self.escalated = escalated
      self.crosspostedSlack = crosspostedSlack
      self.crosspostedLinear = crosspostedLinear
      self.sourceSummary = sourceSummary
      self.topicExcerpt = topicExcerpt
    }
  }

  /// INSERT one immutable audit row. The row is structurally body-free — no
  /// parameter can carry body text; `recipientMemberID` is a TeamMember.id ref,
  /// never the pubkey; `topicExcerpt` is the user's own (already normalized) words.
  public static func append(
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
    topicExcerpt: String?,
    in db: GRDB.Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO \(Schema.HandoffAudit.tableName) (
            \(Schema.HandoffAudit.generatedAtMs),
            \(Schema.HandoffAudit.messageID),
            \(Schema.HandoffAudit.recipientMemberID),
            \(Schema.HandoffAudit.model),
            \(Schema.HandoffAudit.path),
            \(Schema.HandoffAudit.periodStartMs),
            \(Schema.HandoffAudit.periodEndMs),
            \(Schema.HandoffAudit.factCount),
            \(Schema.HandoffAudit.escalated),
            \(Schema.HandoffAudit.crosspostedSlack),
            \(Schema.HandoffAudit.crosspostedLinear),
            \(Schema.HandoffAudit.sourceSummary),
            \(Schema.HandoffAudit.topicExcerpt)
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        generatedAtMs, messageID, recipientMemberID, model, path,
        periodStartMs, periodEndMs, factCount,
        escalated ? 1 : 0, crosspostedSlack ? 1 : 0, crosspostedLinear ? 1 : 0,
        sourceSummary, topicExcerpt,
      ])
  }

  /// Most-recent `limit` rows, newest first (`generated_at_ms DESC`).
  public static func recent(limit: Int, in db: GRDB.Database) throws -> [AuditEntryView] {
    guard limit > 0 else { return [] }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT \(Schema.HandoffAudit.id),
               \(Schema.HandoffAudit.generatedAtMs),
               \(Schema.HandoffAudit.messageID),
               \(Schema.HandoffAudit.recipientMemberID),
               \(Schema.HandoffAudit.model),
               \(Schema.HandoffAudit.path),
               \(Schema.HandoffAudit.periodStartMs),
               \(Schema.HandoffAudit.periodEndMs),
               \(Schema.HandoffAudit.factCount),
               \(Schema.HandoffAudit.escalated),
               \(Schema.HandoffAudit.crosspostedSlack),
               \(Schema.HandoffAudit.crosspostedLinear),
               \(Schema.HandoffAudit.sourceSummary),
               \(Schema.HandoffAudit.topicExcerpt)
          FROM \(Schema.HandoffAudit.tableName)
         ORDER BY \(Schema.HandoffAudit.generatedAtMs) DESC
         LIMIT ?
        """,
      arguments: [limit])
    return rows.compactMap { row in
      guard let id: Int64 = row[Schema.HandoffAudit.id],
        let gen: Int64 = row[Schema.HandoffAudit.generatedAtMs],
        let model: String = row[Schema.HandoffAudit.model],
        let path: String = row[Schema.HandoffAudit.path],
        let pStart: Int64 = row[Schema.HandoffAudit.periodStartMs],
        let pEnd: Int64 = row[Schema.HandoffAudit.periodEndMs],
        let factCount: Int = row[Schema.HandoffAudit.factCount],
        let summary: String = row[Schema.HandoffAudit.sourceSummary]
      else { return nil }
      return AuditEntryView(
        id: id, generatedAtMs: gen,
        messageID: row[Schema.HandoffAudit.messageID] as String?,
        recipientMemberID: row[Schema.HandoffAudit.recipientMemberID] as String?,
        model: model, path: path, periodStartMs: pStart, periodEndMs: pEnd,
        factCount: factCount,
        escalated: (row[Schema.HandoffAudit.escalated] as Int64? ?? 0) != 0,
        crosspostedSlack: (row[Schema.HandoffAudit.crosspostedSlack] as Int64? ?? 0) != 0,
        crosspostedLinear: (row[Schema.HandoffAudit.crosspostedLinear] as Int64? ?? 0) != 0,
        sourceSummary: summary,
        topicExcerpt: row[Schema.HandoffAudit.topicExcerpt] as String?)
    }
  }
}
