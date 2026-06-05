import Foundation
import LeafCore
import LeafMCPProtocol

/// Track AI Coworker P3 — `get_ai_escalation_log` MCP tool. The read-back surface
/// for the §13.4 "AI received" feed: recent `ai_escalation_audit` rows, newest
/// first. Metadata + refs only — never event content. Read-only (the in-app
/// Privacy-feed UI is deferred to the in-app AI surface phase).
struct GetAIEscalationLogTool: ToolExecutor {
  let dbURL: URL
  let dbConfig: DatabaseConfig
  let dbEncryption: EncryptionOptions?

  static let maxLimit = 50
  static let defaultLimit = 20

  static let definition = ToolDefinition(
    name: "get_ai_escalation_log",
    description: """
      Returns the recent log of AI escalations Leaf performed on your behalf (the \
      "AI received" feed). Each entry records WHEN an escalation ran, WHICH model, \
      YOUR question, the count + kinds of events that were sent, and the event id \
      refs — metadata only, never event content. Append-only (escalations cannot \
      be un-sent or erased — audit over temptation).
      """,
    inputSchema: AnyCodable(
      [
        "type": "object",
        "properties": [
          "limit": [
            "type": "integer",
            "description": "Max entries, newest first (default 20, max 50).",
          ]
        ],
      ] as [String: Any])
  )

  func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
    var limit = Self.defaultLimit
    if let dict = arguments?.value as? [String: Any], let raw = dict["limit"] as? Int {
      limit = max(1, min(Self.maxLimit, raw))
    }

    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      return Self.result(
        "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first.",
        isError: true)
    }

    let entries: [AIEscalationAuditStore.AuditEntryView]
    do {
      let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
      entries = try db.recentAIEscalationAudit(limit: limit)
    } catch {
      return Self.result("Couldn't read the escalation log right now. Try again.", isError: true)
    }

    let iso = ISO8601DateFormatter()
    let payload: [String: Any] = [
      "count": entries.count,
      "entries": entries.map { e -> [String: Any] in
        [
          "id": e.id,
          "at": iso.string(from: Date(timeIntervalSince1970: TimeInterval(e.generatedAtMs) / 1000.0)),
          "model": e.model,
          "question": e.questionExcerpt ?? "",
          "source_summary": e.sourceSummary,
          "event_ids": e.eventIDs,
        ]
      },
    ]
    let data = (try? JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    return Self.result(String(data: data, encoding: .utf8) ?? "{}", isError: false)
  }

  private static func result(_ text: String, isError: Bool) -> ToolCallResult {
    ToolCallResult(content: [.text(TextContent(text: text))], isError: isError)
  }
}
