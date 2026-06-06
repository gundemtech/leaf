import Foundation

/// Track AI Coworker P3 — sink for the escalation reverse-audit trail. The row
/// records WHAT was escalated (the consent act + magnitudes + the user's own
/// question), NEVER the body text. Injected so the answerer is unit-testable with
/// a spy and so the actual DB write (a writer-mode open from MCPServer) stays in
/// the app/tool target.
public protocol AuditSink: Sendable {
  func record(_ entry: EscalationAuditEntry) async throws
}

/// One escalation audit row. STRUCTURALLY body-free — there is no field that can
/// hold body text, so even a buggy producer cannot put a body here. Records the
/// consented ids, magnitudes, the user's own question, and the outcome metadata.
public struct EscalationAuditEntry: Sendable, Equatable {
  public let occurredAtMs: Int64
  public let eventIDs: [Int64]
  public let escalatedBodyCount: Int
  public let droppedCount: Int  // selected − escalated (bucket-1 / empty-body omits)
  public let question: String  // the user's OWN normalized question
  public let model: String  // resolved SummarizerModel.rawValue
  public let path: String  // "byok" | "ai_included"
  public let sourceSummary: String  // counts + kinds, never bodies

  public init(
    occurredAtMs: Int64, eventIDs: [Int64], escalatedBodyCount: Int, droppedCount: Int,
    question: String, model: String, path: String, sourceSummary: String
  ) {
    self.occurredAtMs = occurredAtMs
    self.eventIDs = eventIDs
    self.escalatedBodyCount = escalatedBodyCount
    self.droppedCount = droppedCount
    self.question = question
    self.model = model
    self.path = path
    self.sourceSummary = sourceSummary
  }
}

/// Track AI Coworker P3 — testable orchestration for the ESCALATION path
/// (cluster 5: "разобрать детально"). Mirrors `AIWorkAnswerer`, with two added
/// guarantees: the body-bearing `EscalatedBodies` is built through the boundary
/// (`makeEscalation` — bucket-1 drop + cap + provenance), and the reverse-audit
/// row is written BEFORE the network POST — over-record, never under-record
/// (§8 п.4). A failed audit write ABORTS the send, so a body never crosses
/// unrecorded. Lives in LeafCore so SPM tests cover the audit-first discipline;
/// the MCP tool is a thin shell that fetches the selected events and calls this.
public struct AIDetailAnswerer: Sendable {
  public enum Answer: Sendable, Equatable {
    case text(String)
    /// Nothing escalatable in the selection (all bucket-1 / empty) and no
    /// projectable fact — answered locally, no audit, no LLM call.
    case notEnoughData
    /// A user-facing, opaque failure message (never echoes key/body/response).
    case failure(String)
  }

  private let policy: LLMPolicy
  private let summarizer: any Summarizer
  private let modelGate: any ModelGate
  private let audit: any AuditSink
  private let maxAnswerTokens: Int

  public init(
    policy: LLMPolicy,
    summarizer: any Summarizer,
    modelGate: any ModelGate,
    audit: any AuditSink,
    maxAnswerTokens: Int = 1024
  ) {
    self.policy = policy
    self.summarizer = summarizer
    self.modelGate = modelGate
    self.audit = audit
    self.maxAnswerTokens = maxAnswerTokens
  }

  public func answer(
    question rawQuestion: String,
    eventIDs: [Int64],
    selectedEvents: [EgressEvent],
    nowMs: Int64,
    path: InferencePath = .byok,
    preferred: SummarizerModel? = nil
  ) async -> Answer {
    // Body-free structured facts of the SAME selected events (context).
    let context = policy.makeContext(events: selectedEvents)
    // The bodies — bucket-1 drop + cap + provenance, sole-constructed boundary.
    let escalated = policy.makeEscalation(selected: selectedEvents)
    guard !escalated.bodies.isEmpty || !context.facts.isEmpty else { return .notEnoughData }

    let question = policy.makeQuestion(rawQuestion)
    let model = modelGate.model(path: path, preferred: preferred)
    let dropped = max(0, selectedEvents.count - escalated.bodies.count)

    // AUDIT FIRST (over-record, never under-record). A failed write aborts the
    // send — there is NO path where `summarize` runs without a prior successful
    // `audit.record`, so a body can never cross the wire unrecorded.
    let entry = EscalationAuditEntry(
      occurredAtMs: nowMs,
      eventIDs: eventIDs,
      escalatedBodyCount: escalated.bodies.count,
      droppedCount: dropped,
      question: question.text,
      model: model.rawValue,
      path: path.auditLabel,
      sourceSummary: Self.sourceSummary(escalated: escalated, dropped: dropped))
    do {
      try await audit.record(entry)
    } catch {
      return .failure("Couldn't record this request, so it was not sent. Try again.")
    }

    do {
      let out = try await summarizer.summarize(
        context, question: question, escalated: escalated, model: model, maxTokens: maxAnswerTokens)
      return .text(out.text)
    } catch let error as SummarizerError {
      return .failure(AIWorkAnswerer.message(for: error))  // reuse opaque mapping
    } catch {
      return .failure("Couldn't reach the model right now. Try again.")
    }
  }

  /// Counts + kinds only — NEVER bodies. e.g. "2 sent (1 withheld): 2 gh_pr_review_comment_authored".
  static func sourceSummary(escalated: EscalatedBodies, dropped: Int) -> String {
    var counts: [String: Int] = [:]
    for b in escalated.bodies { counts[b.kind, default: 0] += 1 }
    let kinds = counts.sorted { $0.key < $1.key }
      .map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    let dropNote = dropped > 0 ? " (\(dropped) withheld)" : ""
    let base = "\(escalated.bodies.count) sent\(dropNote)"
    return kinds.isEmpty ? base : "\(base): \(kinds)"
  }
}
