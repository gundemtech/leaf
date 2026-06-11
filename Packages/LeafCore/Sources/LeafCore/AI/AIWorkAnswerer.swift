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
    /// A user-facing, opaque failure (kind + message; never echoes key/body).
    case failure(AIFailure)
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
      return .failure(Self.failure(for: error, path: path))
    } catch {
      return .failure(
        AIFailure(kind: .transient, message: "Couldn't reach the model right now. Try again."))
    }
  }

  /// Opaque, user-facing messages — never interpolate key/body/response (§8.1).
  /// AI-UI-4 — path-aware copy. On `.aiIncluded` there is no user-owned
  /// Anthropic key: auth failures point at the Leaf account, and a drained
  /// team pool points at the BYOK valve in Settings.
  public static func message(for error: SummarizerError, path: InferencePath) -> String {
    switch error {
    case .missingAPIKey:
      return "No Anthropic API key configured. Add your key to enable AI answers."
    case .authFailed:
      if path == .aiIncluded {
        return "Couldn't authorize AI answers with your Leaf account. Try again, or sign out and back in."
      }
      return "Your Anthropic API key was rejected (invalid or revoked). Update it and try again."
    case .budgetExhausted:
      if path == .aiIncluded {
        return
          "Your team's included AI budget is used up for now. Add your own Anthropic key in Settings to keep going, or try again later."
      }
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

  /// AI-UI-4 — total kind mapping for `AIFailure` (CTA decisions in views).
  public static func failureKind(for error: SummarizerError) -> AIFailure.Kind {
    switch error {
    case .missingAPIKey: return .missingKey
    case .authFailed: return .auth
    case .budgetExhausted: return .budget
    case .rateLimited: return .rateLimited
    case .attestationFailed: return .attestation
    case .contextEmpty, .badRequest, .serverError, .network, .decode: return .transient
    }
  }

  /// Bundles the kind + path-aware message in one step.
  public static func failure(for error: SummarizerError, path: InferencePath) -> AIFailure {
    AIFailure(kind: failureKind(for: error), message: message(for: error, path: path))
  }
}
