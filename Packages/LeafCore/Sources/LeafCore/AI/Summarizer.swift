import Foundation

/// Models reachable for summarization. Haiku is the default; Sonnet for heavier
/// synthesis; Opus is reachable only with the user's own key. The selection
/// policy is moat and lives in `LeafCorePrivate`; this enum is just the public
/// vocabulary. IDs verified current (claude-api ref).
public enum SummarizerModel: String, Sendable, CaseIterable {
  case haiku
  case sonnet
  case opus

  public var apiModelID: String {
    switch self {
    case .haiku: return "claude-haiku-4-5"
    case .sonnet: return "claude-sonnet-4-6"
    case .opus: return "claude-opus-4-8"
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
}
