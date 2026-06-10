import Foundation

/// AI-UI-3 — recipient-side "Context for me" over an inbound handoff DM.
/// Mirrors `AIDetailAnswerer`: same §8.1 boundary, audit-first discipline.
/// Inputs: the teammate's note (wrapped via `makeInboundHandoff` — labeled
/// foreign data) + the RECIPIENT's own body-free facts. Empty own context →
/// `.notEnoughData` BEFORE any audit/POST (the feature only makes sense
/// against local context). The answer stays local — nothing is sent back.
public struct InboundHandoffExplainer: Sendable {
  public enum Answer: Sendable, Equatable {
    case text(String)
    case notEnoughData
    case failure(String)
  }

  /// Fixed audit label — the instruction text is moat and must not leak into
  /// the M031 table (readable via MCP get_ai_escalation_log).
  public static let auditQuestionLabel = "inbound_handoff_context"

  private let policy: LLMPolicy
  private let summarizer: any Summarizer
  private let modelGate: any ModelGate
  private let prompts: any HandoffPrompts
  private let audit: any AuditSink
  private let maxAnswerTokens: Int

  public init(
    policy: LLMPolicy,
    summarizer: any Summarizer,
    modelGate: any ModelGate,
    prompts: any HandoffPrompts = HandoffPromptMoat.publicSubstrate.prompts,
    audit: any AuditSink,
    maxAnswerTokens: Int = 1024
  ) {
    self.policy = policy
    self.summarizer = summarizer
    self.modelGate = modelGate
    self.prompts = prompts
    self.audit = audit
    self.maxAnswerTokens = maxAnswerTokens
  }

  /// The sender's name is deliberately NOT a parameter (review HIGH-1): the
  /// display name is sender-supplied plaintext, and foreign text enters the
  /// prompt only inside the labeled `EscalatedBodies` data slot.
  public func explain(
    handoffText: String,
    events: [EgressEvent],
    sentAtMs: Int64,
    nowMs: Int64,
    path: InferencePath = .byok,
    preferred: SummarizerModel? = nil
  ) async -> Answer {
    let context = policy.makeContext(events: events)
    guard !context.facts.isEmpty else { return .notEnoughData }
    let escalated = policy.makeInboundHandoff(text: handoffText, tsMs: sentAtMs)
    guard !escalated.bodies.isEmpty else { return .notEnoughData }

    let question = policy.makeQuestion(prompts.inboundContextInstruction())
    let model = modelGate.model(path: path, preferred: preferred)

    // AUDIT FIRST (§8 п.4 — over-record, never under-record); a failed write
    // aborts the send, so the teammate's note never crosses unrecorded.
    let entry = EscalationAuditEntry(
      occurredAtMs: nowMs,
      eventIDs: [],
      escalatedBodyCount: escalated.bodies.count,
      droppedCount: 0,
      question: Self.auditQuestionLabel,
      model: model.rawValue,
      path: path.auditLabel,
      sourceSummary: "1 inbound_handoff")
    do {
      try await audit.record(entry)
    } catch {
      return .failure("Couldn't record this request, so it was not sent. Try again.")
    }

    do {
      let out = try await summarizer.summarize(
        context, question: question, escalated: escalated, model: model,
        maxTokens: maxAnswerTokens)
      return .text(out.text)
    } catch let error as SummarizerError {
      return .failure(AIWorkAnswerer.message(for: error))
    } catch {
      return .failure("Couldn't reach the model right now. Try again.")
    }
  }
}
