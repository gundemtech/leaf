import Foundation

/// Models reachable for summarization. Haiku is the default; Sonnet for heavier
/// synthesis; Opus is reachable only with the user's own key. The selection
/// policy is moat and lives in `LeafCorePrivate`; this enum is just the public
/// vocabulary. IDs verified current (claude-api ref).
public enum SummarizerModel: String, Sendable, CaseIterable {
  case haiku
  case sonnet
  case opus
  /// P5 (v1.5) — the open-weight model served on the verifiable attested path.
  /// Claude is not attestable, so the verifiable tier runs open-weight instead.
  case attestedOpenWeight

  public var apiModelID: String {
    switch self {
    case .haiku: return "claude-haiku-4-5"
    case .sonnet: return "claude-sonnet-4-6"
    case .opus: return "claude-opus-4-8"
    // Placeholder — NEVER sent: the attested path posts `rawValue`, resolved to the
    // served model server-side (mirrors RelayProxySummarizer). This arm exists only
    // for switch exhaustiveness and is unreachable from the BYOK-direct path.
    case .attestedOpenWeight: return "open-weight"
    }
  }

  public static let `default`: SummarizerModel = .haiku
}

public struct TokenUsage: Sendable, Equatable {
  public let inputTokens: Int
  public let outputTokens: Int
  public init(inputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

public struct SummarizerOutput: Sendable, Equatable {
  public let text: String
  public let usage: TokenUsage
  /// Echo of the API `response.model` — lets callers/tests confirm the model.
  public let modelUsed: String
  public let stopReason: String?

  public init(text: String, usage: TokenUsage, modelUsed: String, stopReason: String?) {
    self.text = text
    self.usage = usage
    self.modelUsed = modelUsed
    self.stopReason = stopReason
  }
}

/// Typed errors for the BYOK inference path (kept out of the core `LeafError`
/// enum — the established convention is a per-integration error type, cf.
/// `GitHubTokenRefresherError`).
public enum SummarizerError: Error, Equatable, Sendable {
  case missingAPIKey
  case authFailed(String)  // 401 — bad/revoked key; do not retry
  case rateLimited(retryAfter: Int?)  // 429
  case serverError(Int)  // 5xx / 529 — retryable
  case badRequest(String)  // 400 — our payload is wrong (bug)
  case network(String)
  case decode(String)
  case contextEmpty
  case budgetExhausted(retryAfter: Int?)  // 402 — hard stop (team overdraft disabled)
  /// P5 — the verifiable (attested) path could not prove the inference enclave, so
  /// the prompt was NOT sent (fail-closed). Opaque reason; never the report bytes.
  case attestationFailed(String)
}

/// Produces a natural-language summary over an already-egress-filtered context.
/// The ONLY input is a `PromptSafeContext` (opaque, constructible only via
/// `LLMPolicy.makeContext`) — so no event can reach the LLM without passing the
/// egress boundary (§8.1, compile-time guarantee).
public protocol Summarizer: Sendable {
  func summarize(
    _ context: PromptSafeContext,
    model: SummarizerModel,
    maxTokens: Int
  ) async throws -> SummarizerOutput

  /// P1 — question-aware overload for the Default Q&A path. The `question` is a
  /// `PromptSafeQuestion` (the user's own normalized input, see `LLMPolicy.makeQuestion`).
  /// The default implementation forwards to the no-question method, so existing
  /// conformers (`NoOpSummarizer`, test fakes) compile and behave unchanged;
  /// production summarizers override it to thread the question into the prompt.
  func summarize(
    _ context: PromptSafeContext,
    question: PromptSafeQuestion,
    model: SummarizerModel,
    maxTokens: Int
  ) async throws -> SummarizerOutput

  /// P3 — escalation overload. Carries the body-free `context` AND the opaque
  /// body-bearing `escalated` payload (the explicitly-selected, consented event
  /// bodies). The default implementation IGNORES `escalated` and forwards to the
  /// QA overload — so a summarizer that has not opted into the body-bearing path
  /// NEVER ships a body (fail-safe: an un-upgraded backend silently degrades to
  /// body-free, never the reverse). Production backends override it to render the
  /// retrieved-bodies-as-DATA segment with anti-injection framing.
  func summarize(
    _ context: PromptSafeContext,
    question: PromptSafeQuestion,
    escalated: EscalatedBodies,
    model: SummarizerModel,
    maxTokens: Int
  ) async throws -> SummarizerOutput
}

extension Summarizer {
  public func summarize(
    _ context: PromptSafeContext,
    question: PromptSafeQuestion,
    model: SummarizerModel,
    maxTokens: Int
  ) async throws -> SummarizerOutput {
    try await summarize(context, model: model, maxTokens: maxTokens)
  }

  public func summarize(
    _ context: PromptSafeContext,
    question: PromptSafeQuestion,
    escalated: EscalatedBodies,
    model: SummarizerModel,
    maxTokens: Int
  ) async throws -> SummarizerOutput {
    // Fail-safe default: drop the bodies, answer body-free. A backend that
    // forgets to override degrades to a weaker-but-safe answer, never a leak.
    try await summarize(context, question: question, model: model, maxTokens: maxTokens)
  }
}
