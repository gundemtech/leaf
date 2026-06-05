import Foundation

/// Track AI Coworker P4 — the AI *provenance* of one team handoff draft, carried
/// from draft time to the SEND-time audit (M032). STRUCTURALLY body-free — there
/// is no field that can hold body text. `topicExcerpt` is the user's OWN
/// normalized topic (the same `makeQuestion` output that bounded the prompt);
/// `sourceSummary` is counts+kinds of the projected facts, never bodies.
public struct HandoffProvenance: Sendable, Equatable {
  public let periodStartMs: Int64
  public let periodEndMs: Int64
  public let model: String  // resolved SummarizerModel.rawValue
  public let path: String  // "byok" | "ai_included"
  public let sourceSummary: String  // counts + kinds, never bodies
  public let factCount: Int
  /// Always `false` in P4 (default body-free draft). Present so the audit schema
  /// is forward-compatible when the "копнуть глубже" escalation draft lands.
  public let escalated: Bool
  public let topicExcerpt: String  // user's OWN normalized topic (makeQuestion output)

  public init(
    periodStartMs: Int64, periodEndMs: Int64, model: String, path: String,
    sourceSummary: String, factCount: Int, escalated: Bool, topicExcerpt: String
  ) {
    self.periodStartMs = periodStartMs
    self.periodEndMs = periodEndMs
    self.model = model
    self.path = path
    self.sourceSummary = sourceSummary
    self.factCount = factCount
    self.escalated = escalated
    self.topicExcerpt = topicExcerpt
  }
}

/// Track AI Coworker P4 — testable orchestration for the team-handoff DRAFT path
/// (§6/§13.6). Mirrors `AIWorkAnswerer`: `[EgressEvent]` → `LLMPolicy.makeContext`
/// (the SAME §8.1 boundary as the Default Q&A path — NOT a new barrier, §8 п.1) →
/// `ModelGate` → `Summarizer`. Reuses the **existing QA overload** — the handoff
/// framing (topic + recipient name + "write a handoff note") is public product
/// copy folded into ONE instruction string, then normalized through
/// `makeQuestion` (whitespace-collapse + cap — the N-4 anti-injection control,
/// applied to topic AND recipient name together). Pure (no DB, no side effects);
/// the SEND-time M032 audit is the app's job, so the drafter only *carries*
/// `HandoffProvenance`. Default body-free only — escalation (bodies) is deferred.
public struct HandoffDrafter: Sendable {
  public enum Draft: Sendable, Equatable {
    /// The drafted note + the provenance of the facts that produced it.
    case text(String, provenance: HandoffProvenance)
    /// Nothing in the period projected to a shareable fact — answered locally,
    /// no LLM call (saves a guaranteed `.contextEmpty`).
    case notEnoughData
    /// A user-facing, opaque failure message (never echoes key/body/response).
    case failure(String)
  }

  private let policy: LLMPolicy
  private let summarizer: any Summarizer
  private let modelGate: any ModelGate
  private let maxDraftTokens: Int

  public init(
    policy: LLMPolicy,
    summarizer: any Summarizer,
    modelGate: any ModelGate,
    maxDraftTokens: Int = 1024
  ) {
    self.policy = policy
    self.summarizer = summarizer
    self.modelGate = modelGate
    self.maxDraftTokens = maxDraftTokens
  }

  /// `topic` = the user's own words (what the handoff is about); `recipientName`
  /// = the teammate's display name. Both enter the prompt ONLY through
  /// `makeQuestion` (folded into one string, then collapsed+capped) — the
  /// recipient `displayName` is NEVER interpolated raw. `recipientName` is new
  /// egress to the LLM vs the QA path (acceptable: the user's own teammate,
  /// UI-supplied, not corpus-derived; NOT added to any `EgressEvent`). `period`
  /// is used only to stamp provenance (keeps the drafter DB-free).
  public func draft(
    topic: String,
    recipientName: String,
    events: [EgressEvent],
    period: DateInterval,
    path: InferencePath = .byok,
    preferred: SummarizerModel? = nil
  ) async -> Draft {
    let context = policy.makeContext(events: events)
    guard !context.facts.isEmpty else { return .notEnoughData }

    // Prompt: topic + recipient name + framing, all normalized together (B/F5).
    let question = policy.makeQuestion(Self.handoffInstruction(topic: topic, recipientName: recipientName))
    let model = modelGate.model(path: path, preferred: preferred)
    do {
      let out = try await summarizer.summarize(
        context, question: question, model: model, maxTokens: maxDraftTokens)
      let provenance = HandoffProvenance(
        periodStartMs: Int64(period.start.timeIntervalSince1970 * 1000),
        periodEndMs: Int64(period.end.timeIntervalSince1970 * 1000),
        model: model.rawValue,
        path: path == .byok ? "byok" : "ai_included",
        sourceSummary: Self.sourceSummary(context),
        factCount: context.facts.count,
        escalated: false,
        // Audit excerpt = the user's OWN topic, normalized the same way (NOT the
        // framing/recipient — just the user's words). Single source of truth.
        topicExcerpt: policy.makeQuestion(topic).text)
      return .text(out.text, provenance: provenance)
    } catch let error as SummarizerError {
      return .failure(AIWorkAnswerer.message(for: error))  // reuse opaque mapping
    } catch {
      return .failure("Couldn't draft right now. Try again.")
    }
  }

  /// PUBLIC framing — product copy, not a secret. Folds topic + recipient into a
  /// single instruction that `makeQuestion` then normalizes. Reuses the QA system
  /// prompt's "facts strictly as data" discipline via the QA overload.
  static func handoffInstruction(topic: String, recipientName: String) -> String {
    "Write a short, friendly work handoff note for my teammate \(recipientName) about: \(topic). "
      + "Cover what I worked on, what is in progress, what is blocking me, and where I stopped, "
      + "using ONLY the structured facts. Write in the first person, ready to send."
  }

  /// Counts + kinds of the projected (body-free) facts — never bodies. e.g.
  /// "recap_metrics, 2 blocker_fact, 1 cross_link_fact". Mirrors
  /// `AIDetailAnswerer.sourceSummary`'s shape, over `PromptSafeContext`.
  static func sourceSummary(_ context: PromptSafeContext) -> String {
    var counts: [String: Int] = [:]
    for f in context.facts { counts[f.kind, default: 0] += 1 }
    let kinds = counts.sorted { $0.key < $1.key }
      .map { $0.value == 1 ? $0.key : "\($0.value) \($0.key)" }
      .joined(separator: ", ")
    return kinds.isEmpty ? "0 facts" : kinds
  }
}
