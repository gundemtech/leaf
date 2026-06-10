import Foundation

/// AI-UI-2 — формат строк двух Privacy-лент (Settings → Sharing → AI privacy)
/// из audit-таблиц M031/M032. Pure (по образцу TeamFeedPresentation). Тела в
/// audit-таблицах структурно отсутствуют — presentation только переупаковывает
/// metadata. Raw member-id в UI не отдаём — резолв или "Former teammate".
public enum AIPrivacyFeedPresentation {
  public struct EscalationRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let at: Date
    public let model: String
    public let eventCount: Int
    public let question: String?  // own excerpt (M031)
    public let sourceSummary: String
  }

  public struct HandoffRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let at: Date
    public let recipientName: String  // резолв по member id, fallback
    public let model: String
    public let path: String  // "byok" | "ai_included"
    public let factCount: Int
    public let topic: String?  // own excerpt (M032)
    public let crosspostedSlack: Bool
    public let crosspostedLinear: Bool
  }

  public static func escalationRows(
    _ entries: [AIEscalationAuditStore.AuditEntryView]
  ) -> [EscalationRow] {
    entries.map {
      EscalationRow(
        id: $0.id,
        at: Date(timeIntervalSince1970: TimeInterval($0.generatedAtMs) / 1000.0),
        model: $0.model, eventCount: $0.eventIDs.count,
        question: $0.questionExcerpt, sourceSummary: $0.sourceSummary)
    }
  }

  public static func handoffRows(
    _ entries: [HandoffAuditStore.AuditEntryView], members: [TeamMember]
  ) -> [HandoffRow] {
    entries.map { e in
      let name: String = {
        guard let mid = e.recipientMemberID,
          let m = members.first(where: { $0.id == mid })
        else { return "Former teammate" }
        return m.displayName
      }()
      return HandoffRow(
        id: e.id,
        at: Date(timeIntervalSince1970: TimeInterval(e.generatedAtMs) / 1000.0),
        recipientName: name, model: e.model, path: e.path, factCount: e.factCount,
        topic: e.topicExcerpt,
        crosspostedSlack: e.crosspostedSlack, crosspostedLinear: e.crosspostedLinear)
    }
  }
}
