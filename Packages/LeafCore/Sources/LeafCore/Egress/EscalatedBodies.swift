import Foundation

/// One explicitly-selected event's body, projected for escalation (Track AI
/// Coworker P3): capped, provenance-tagged, bucket-1-cleared. OUTPUT-shaped —
/// it carries no raw payload, only the fields the escalation prompt may see.
public struct EscalatedBody: Sendable, Equatable {
  public let kind: String
  public let tsBucketMs: Int64
  /// true == the viewer authored this text (own content, low injection risk).
  /// false == someone else's text — treated as HOSTILE data for injection
  /// purposes (labeled as such in the rendered prompt).
  public let authoredByViewer: Bool
  /// The capped body text — the ONLY free-text value that crosses on this path.
  public let text: String

  /// Public: OUTPUT-shaped, already capped — there is nothing unsafe to
  /// construct here (mirrors `ProjectedFact.init` being public). The boundary
  /// is the opacity of the *collection* (`EscalatedBodies`).
  public init(kind: String, tsBucketMs: Int64, authoredByViewer: Bool, text: String) {
    self.kind = kind
    self.tsBucketMs = tsBucketMs
    self.authoredByViewer = authoredByViewer
    self.text = text
  }
}

/// The body-bearing escalation payload. Like `PromptSafeContext`, it has **no
/// public initializer** — the sole constructor is `LLMPolicy.makeEscalation`
/// (bucket-1 drop + cap + provenance). A `Summarizer` accepts it ONLY on the
/// escalation overload; the default + QA overloads cannot receive one (separate
/// type → compile-time separation; the default-path type structurally cannot
/// carry a body). Carries ONLY the explicitly-selected, consented event bodies
/// (§8 P3 consent act).
public struct EscalatedBodies: Sendable, Equatable {
  public let bodies: [EscalatedBody]

  /// Internal: only `LeafCore` (`LLMPolicy.makeEscalation`) constructs this.
  /// Tests reach it via `@testable import`; prod app/agent/mcp targets cannot.
  internal init(bodies: [EscalatedBody]) {
    self.bodies = bodies
  }
}
