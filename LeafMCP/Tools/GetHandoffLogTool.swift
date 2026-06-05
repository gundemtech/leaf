import Foundation
import LeafCore
import LeafMCPProtocol

/// Track AI Coworker P4 — `get_handoff_log` MCP tool. The read-back surface for
/// the "AI handoffs" feed: recent `handoff_audit` rows (M032), newest first.
/// Metadata + refs only — never the handoff body, never the recipient pubkey.
/// Read-only (the in-app Privacy-feed UI is deferred to the in-app AI surface
/// phase, like the P3 escalation log).
struct GetHandoffLogTool: ToolExecutor {
  let dbURL: URL
  let dbConfig: DatabaseConfig
  let dbEncryption: EncryptionOptions?

  static let maxLimit = 50
  static let defaultLimit = 20

  static let definition = ToolDefinition(
    name: "get_handoff_log",
    description: """
      Returns the recent log of AI-assisted team handoffs Leaf composed + sent on \
      your behalf. Each entry records WHEN it was sent, to WHICH teammate (an \
      opaque member id), WHICH model drafted it, the period + count/kinds of facts \
      that informed it, your own topic, and whether the body also cross-posted off \
      the encrypted channel to Slack/Linear — metadata only, never the handoff \
      body. Append-only (sent handoffs cannot be un-sent or erased — audit over \
      temptation).
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

    let entries: [HandoffAuditStore.AuditEntryView]
    do {
      let db = try Database.openForRead(at: dbURL, config: dbConfig, encryption: dbEncryption)
      entries = try db.recentHandoffAudit(limit: limit)
    } catch {
      return Self.result("Couldn't read the handoff log right now. Try again.", isError: true)
    }

    let iso = ISO8601DateFormatter()
    let payload: [String: Any] = [
      "count": entries.count,
      "entries": entries.map { e -> [String: Any] in
        [
          "id": e.id,
          "at": iso.string(from: Date(timeIntervalSince1970: TimeInterval(e.generatedAtMs) / 1000.0)),
          "recipient_member_id": e.recipientMemberID ?? "",
          "model": e.model,
          "topic": e.topicExcerpt ?? "",
          "source_summary": e.sourceSummary,
          "fact_count": e.factCount,
          "crossposted_slack": e.crosspostedSlack,
          "crossposted_linear": e.crosspostedLinear,
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
