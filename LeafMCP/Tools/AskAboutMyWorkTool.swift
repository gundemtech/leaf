import Foundation
import LeafCore
import LeafMCPProtocol

/// Track AI Coworker P1 — `ask_about_my_work` MCP tool. The first live consumer
/// of the QueryEngine→boundary→Summarizer pipeline (clusters 1–2: recap + resume).
///
/// Thin shell: decode args → gather on-device facts (`WorkFactGatherer`) →
/// hand to `AIWorkAnswerer` (boundary + ModelGate + Summarizer, all testable in
/// LeafCore). BYOK-only live in P1 (`.byok`); the answer is the user's own data
/// returning to the user's own AI client.
///
/// ADR-019 note: MCPServer otherwise only READS the DB; this tool additionally
/// makes ONE user-initiated outbound HTTPS call to Anthropic with the user's BYOK
/// key. It does not write the DB or the key file (only the user writes the key).
struct AskAboutMyWorkTool: ToolExecutor {
  let dbURL: URL
  let dbConfig: DatabaseConfig
  let dbEncryption: EncryptionOptions?
  let policy: LLMPolicy
  let summarizerMoat: AISummarizerMoat
  let modelGateMoat: ModelGateMoat

  static let maxAnswerTokens = 1024

  static let definition = ToolDefinition(
    name: "ask_about_my_work",
    description: """
      Answers a natural-language question about YOUR OWN work as a short written \
      recap/answer, via a privacy-preserving on-device→LLM pipeline. Handles \
      recap ("what did I do this week"), resume ("where did I stop", "what's \
      blocking me"), cross-provider links ("which PR maps to which Linear task"), \
      and patterns/trends ("how long do my PRs take to merge", "what are my \
      streaks", "how's this week vs last"). Use this when the user wants a written \
      summary; for raw structured data use the leaf_query_* / get_* tools instead. \
      NB: this makes one outbound call to Anthropic with the user's own (BYOK) API key.
      """,
    inputSchema: AnyCodable(
      [
        "type": "object",
        "properties": [
          "question": [
            "type": "string", "description": "Your question about your own work.",
          ],
          "period": [
            "type": "string", "enum": ["today", "yesterday", "last_7_days"],
            "description": "Time window for the recap (default: today).",
          ],
          "model": [
            "type": "string", "enum": ["haiku", "sonnet", "opus"],
            "description": "Optional model preference (default: haiku).",
          ],
        ],
        "required": ["question"],
      ] as [String: Any])
  )

  func execute(arguments: AnyCodable?) async throws -> ToolCallResult {
    let request: AskParams.Request
    switch AskParams.decode(arguments: arguments?.value) {
    case .error(let msg):
      throw MCPProtocolError.invalidParams(msg)
    case .ok(let r):
      request = r
    }

    guard FileManager.default.fileExists(atPath: dbURL.path) else {
      return Self.result(
        "Leaf database not found at \(dbURL.path). Enable 'Background collection' in Settings first.",
        isError: true)
    }

    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    let gatherer = WorkFactGatherer(dbURL: dbURL, dbConfig: dbConfig, dbEncryption: dbEncryption)
    let events: [EgressEvent]
    do {
      events = try gatherer.gather(period: request.period.interval(), nowMs: nowMs)
    } catch {
      return Self.result("Couldn't read your activity right now. Try again.", isError: true)
    }

    let answerer = AIWorkAnswerer(
      policy: policy, summarizer: summarizerMoat.summarizer, modelGate: modelGateMoat.gate,
      maxAnswerTokens: Self.maxAnswerTokens)
    switch await answerer.answer(
      question: request.question, events: events, path: .byok, preferred: request.preferredModel)
    {
    case .text(let text):
      return Self.result(text, isError: false)
    case .notEnoughData:
      return Self.result(
        "I don't have enough recorded work in that period to answer.", isError: false)
    case .failure(let failure):
      return Self.result(failure.message, isError: true)
    }
  }

  private static func result(_ text: String, isError: Bool) -> ToolCallResult {
    ToolCallResult(content: [.text(TextContent(text: text))], isError: isError)
  }
}
