import Foundation

/// Track AI Coworker P1 — testable orchestration for the Default Q&A path:
/// `[EgressEvent]` → `LLMPolicy.makeContext` (the boundary) → `ModelGate` →
/// `Summarizer`. Lives in LeafCore so SPM tests cover the empty-facts shortcut +
/// the `SummarizerError`→message mapping without xcodebuild (LeafMCP has no SPM
/// test target). The MCP tool is a thin shell that gathers events and calls this.
/// Reusable by a future in-app surface.
public struct AIWorkAnswerer: Sendable {
  public enum Answer: Sendable, Equatable {
    /// The model's written answer.
    case text(String)
    /// Nothing recorded in the period projected to a shareable fact — answered
    /// locally, no LLM call (saves a guaranteed `.contextEmpty`).
    case notEnoughData
    /// A user-facing, opaque failure message (never echoes key/body).
    case failure(String)
  }

  private let policy: LLMPolicy
  private let summarizer: any Summarizer
  private let modelGate: any ModelGate
  private let maxAnswerTokens: Int

  public init(
    policy: LLMPolicy,
    summarizer: any Summarizer,
    modelGate: any ModelGate,
    maxAnswerTokens: Int = 1024
  ) {
    self.policy = policy
    self.summarizer = summarizer
    self.modelGate = modelGate
    self.maxAnswerTokens = maxAnswerTokens
  }

  public func answer(
    question rawQuestion: String,
    events: [EgressEvent],
    path: InferencePath = .byok,
    preferred: SummarizerModel? = nil
  ) async -> Answer {
    let context = policy.makeContext(events: events)
    guard !context.facts.isEmpty else { return .notEnoughData }

    let question = policy.makeQuestion(rawQuestion)
    let model = modelGate.model(path: path, preferred: preferred)
    do {
      let out = try await summarizer.summarize(
        context, question: question, model: model, maxTokens: maxAnswerTokens)
      return .text(out.text)
    } catch let error as SummarizerError {
      return .failure(Self.message(for: error))
    } catch {
      return .failure("Couldn't reach the model right now. Try again.")
    }
  }

  /// Opaque, user-facing messages — never interpolate key/body/response (§8.1).
  public static func message(for error: SummarizerError) -> String {
    switch error {
    case .missingAPIKey:
      return "No Anthropic API key configured. Add your key to enable AI answers."
    case .authFailed:
      return "Your Anthropic API key was rejected (invalid or revoked). Update it and try again."
    case .budgetExhausted:
      return "AI inference budget exhausted. Try again later."
    case .rateLimited:
      return "Rate limited by the model provider. Try again shortly."
    case .contextEmpty:
      return "I don't have enough recorded work in that period to answer."
    case .attestationFailed:
      return "Couldn't verify the inference enclave, so nothing was sent. Try again."
    case .badRequest, .serverError, .network, .decode:
      return "Couldn't reach the model right now. Try again."
    }
  }
}
