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
    /// A user-facing, opaque failure (kind + message; never echoes key/body/response).
    case failure(AIFailure)
  }

  private let policy: LLMPolicy
  private let summarizer: any Summarizer
  private let modelGate: any ModelGate
  private let prompts: any HandoffPrompts
  /// AI-UI-3 — M031 sink for the escalated redraft path. nil is valid for the
  /// body-free-only callers; an escalated draft WITHOUT a sink fails closed.
  private let audit: (any AuditSink)?
  private let maxDraftTokens: Int

  public init(
    policy: LLMPolicy,
    summarizer: any Summarizer,
    modelGate: any ModelGate,
    prompts: any HandoffPrompts = HandoffPromptMoat.publicSubstrate.prompts,
    audit: (any AuditSink)? = nil,
    maxDraftTokens: Int = 1024
  ) {
    self.policy = policy
    self.summarizer = summarizer
    self.modelGate = modelGate
    self.prompts = prompts
    self.audit = audit
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
    preferred: SummarizerModel? = nil,
    escalated: EscalatedBodies? = nil,
    escalatedEventIDs: [Int64] = []
  ) async -> Draft {
    let context = policy.makeContext(events: events)
    guard !context.facts.isEmpty else { return .notEnoughData }

    // AI-UI-3 — a degenerate escalation (all dropped / empty selection) is the
    // body-free path: nothing crosses, so no audit row and escalated == false.
    let bodies = escalated?.bodies ?? []
    let isEscalated = !bodies.isEmpty

    // Prompt: topic + recipient name + framing, all normalized together (B/F5).
    // AI-UI-3 — the framing text comes from the prompt seam (moat under
    // LEAF_PROD, public copy otherwise); discipline unchanged.
    let instruction = isEscalated
      ? prompts.redraftInstruction(topic: topic, recipientName: recipientName)
      : prompts.draftInstruction(topic: topic, recipientName: recipientName)
    let question = policy.makeQuestion(instruction)
    let model = modelGate.model(path: path, preferred: preferred)

    if isEscalated, let escalated {
      // AUDIT FIRST (§8 п.4 — over-record, never under-record). No sink wired →
      // fail closed: a body must never cross unrecorded.
      guard let audit else {
        return .failure(
          AIFailure(
            kind: .auditWrite,
            message: "Couldn't record this request, so it was not sent. Try again."))
      }
      let dropped = max(0, escalatedEventIDs.count - bodies.count)
      let entry = EscalationAuditEntry(
        occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000),
        eventIDs: escalatedEventIDs,
        escalatedBodyCount: bodies.count,
        droppedCount: dropped,
        // The user's OWN topic words — NEVER the instruction text (the prod
        // instruction is moat and this row is readable via get_ai_escalation_log).
        question: policy.makeQuestion(topic).text,
        model: model.rawValue,
        path: path.auditLabel,
        sourceSummary: AIDetailAnswerer.sourceSummary(escalated: escalated, dropped: dropped))
      do {
        try await audit.record(entry)
      } catch {
        return .failure(
          AIFailure(
            kind: .auditWrite,
            message: "Couldn't record this request, so it was not sent. Try again."))
      }
    }

    do {
      let out: SummarizerOutput
      if isEscalated, let escalated {
        out = try await summarizer.summarize(
          context, question: question, escalated: escalated, model: model,
          maxTokens: maxDraftTokens)
      } else {
        out = try await summarizer.summarize(
          context, question: question, model: model, maxTokens: maxDraftTokens)
      }
      let provenance = HandoffProvenance(
        periodStartMs: Int64(period.start.timeIntervalSince1970 * 1000),
        periodEndMs: Int64(period.end.timeIntervalSince1970 * 1000),
        model: model.rawValue,
        path: path.auditLabel,
        sourceSummary: isEscalated
          ? Self.sourceSummary(context) + " + \(bodies.count) bodies"
          : Self.sourceSummary(context),
        factCount: context.facts.count,
        escalated: isEscalated,
        // Audit excerpt = the user's OWN topic, normalized the same way (NOT the
        // framing/recipient — just the user's words). Single source of truth.
        topicExcerpt: policy.makeQuestion(topic).text)
      return .text(out.text, provenance: provenance)
    } catch let error as SummarizerError {
      return .failure(AIWorkAnswerer.failure(for: error, path: path))  // reuse opaque mapping
    } catch {
      return .failure(AIFailure(kind: .transient, message: "Couldn't draft right now. Try again."))
    }
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
