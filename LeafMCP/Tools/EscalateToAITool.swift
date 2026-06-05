import Foundation
import LeafCore
import LeafMCPProtocol

/// Track AI Coworker P3 — `escalate_to_ai` MCP tool. The body-bearing escalation
/// path (cluster 5: "разобрать детально"). Takes EXPLICIT `event_ids` (the
/// consent act), fetches those events' bodies on-device, projects them through
/// `LLMPolicy.makeEscalation` (bucket-1 drop + cap + provenance), writes the
/// reverse-audit row (audit-first), then asks the LLM.
///
/// ADR-019 departure (P3): MCPServer is otherwise a reader; this tool opens a
/// brief `openForWrite` handle (via `DBEscalationAuditSink`) to append ONE
/// `ai_escalation_audit` row BEFORE the outbound POST — "every escalation is
/// audited" (§8 п.4). It also makes ONE outbound HTTPS call to Anthropic with the
/// user's BYOK key (the P1 `ask_about_my_work` departure). BYOK-only live.
struct EscalateToAITool: ToolExecutor {
  let dbURL: URL
  let dbConfig: DatabaseConfig
  let dbEncryption: EncryptionOptions?
  let policy: LLMPolicy
  let summarizerMoat: AISummarizerMoat
  let modelGateMoat: ModelGateMoat

  static let maxAnswerTokens = 1024

  static let definition = ToolDefinition(
    name: "escalate_to_ai",
    description: """
      Sends the FULL TEXT (bodies) of the specified events to the model for a \
      detailed breakdown — e.g. "summarize the discussion in PR #42" or "recap \
      this Linear thread". Pass the exact event_ids (from get_timeline / \
      leaf_query_activity / get_cross_provider_thread). Unlike ask_about_my_work \
      (which sends only structured facts), this escalates the event bodies — so \
      EVERY call is recorded in an append-only local audit log (see \
      get_ai_escalation_log). Personal-app and DM bodies are never sent even if \
      their ids are named. Makes one outbound call to Anthropic with the user's \
      own (BYOK) API key.
      """,
    inputSchema: AnyCodable(
      [
        "type": "object",
        "properties": [
          "question": [
            "type": "string", "description": "What to do with these events' text.",
          ],
          "event_ids": [
            "type": "array", "items": ["type": "integer"],
            "description": "Exact ids of the events whose text to analyze (the consent act).",
          ],
          "model": [
            "type": "string", "enum": ["haiku", "sonnet", "opus"],
            "description": "Optional model preference (default: haiku).",
          ],
        ],
        "required": ["question", "event_ids"],
      ] as [String: Any])
  )

  func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
    guard let dict = arguments?.value as? [String: Any],
      let question = (dict["question"] as? String),
      !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MCPProtocolError.invalidParams("`question` is required")
    }
    let eventIDs: [Int64] = (dict["event_ids"] as? [Any] ?? []).compactMap {
      if let i = $0 as? Int { return Int64(i) }
      if let i = $0 as? Int64 { return i }
      if let n = $0 as? NSNumber { return n.int64Value }
      return nil
    }
    guard !eventIDs.isEmpty else {
      throw MCPProtocolError.invalidParams("`event_ids` must be a non-empty array of integers")
    }
    let preferred: SummarizerModel? = (dict["model"] as? String).flatMap(SummarizerModel.init(rawValue:))

    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      return Self.result(
        "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first.",
        isError: true)
    }

    let gatherer = WorkFactGatherer(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
    let selected: [EgressEvent]
    do {
      selected = try gatherer.gatherSelectedBodies(eventIDs: eventIDs)
    } catch {
      return Self.result("Couldn't read those events right now. Try again.", isError: true)
    }

    let audit = DBEscalationAuditSink(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
    let answerer = AIDetailAnswerer(
      policy: policy, summarizer: summarizerMoat.summarizer, modelGate: modelGateMoat.gate,
      audit: audit, maxAnswerTokens: Self.maxAnswerTokens)
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

    switch await answerer.answer(
      question: question, eventIDs: eventIDs, selectedEvents: selected, nowMs: nowMs,
      path: .byok, preferred: preferred)
    {
    case .text(let text):
      return Self.result(text, isError: false)
    case .notEnoughData:
      return Self.result(
        "None of those events have text I can analyze (they may be personal-app / DM events, which are never sent).",
        isError: false)
    case .failure(let message):
      return Self.result(message, isError: true)
    }
  }

  private static func result(_ text: String, isError: Bool) -> ToolCallResult {
    ToolCallResult(content: [.text(TextContent(text: text))], isError: isError)
  }
}

/// Prod escalation audit sink: opens a brief `openForWrite` handle and appends
/// ONE row (ADR-019 departure — MCPServer is otherwise a reader; supported by WAL
/// + cross-process POSIX locks). Audit-first ordering is enforced by
/// `AIDetailAnswerer` (the writer fails → the send aborts).
struct DBEscalationAuditSink: AuditSink {
  let dbURL: URL
  let dbConfig: DatabaseConfig
  let dbEncryption: EncryptionOptions?

  func record(_ entry: EscalationAuditEntry) async throws {
    let db = try Database.openForWrite(at: dbURL, config: dbConfig, encryption: dbEncryption)
    try db.appendAIEscalationAudit(
      generatedAtMs: entry.occurredAtMs,
      questionExcerpt: entry.question,
      model: entry.model,
      eventIDs: entry.eventIDs,
      sourceSummary: entry.sourceSummary)
  }
}
