import Foundation

/// One projected, cloud-safe event in a prompt context.
public struct ProjectedFact: Sendable, Equatable {
  public let kind: String
  public let tsBucketMs: Int64
  /// OUTPUT-named, allow-listed, body-free fields (see `FactProjection`).
  public let fields: [String: String]

  public init(kind: String, tsBucketMs: Int64, fields: [String: String]) {
    self.kind = kind
    self.tsBucketMs = tsBucketMs
    self.fields = fields
  }
}

/// The ONLY value a `Summarizer` accepts. It has **no public initializer**, so
/// app-target code cannot construct one — the sole construction path is
/// `LLMPolicy.makeContext`. This makes it a compile-time guarantee that no
/// event reaches the cloud LLM without passing the egress projection (Track AI
/// Coworker §8.1 — the type guards the topology; the sentinel tests guard the
/// content).
public struct PromptSafeContext: Sendable, Equatable {
  public let facts: [ProjectedFact]

  /// Internal: only `LeafCore` (i.e. `LLMPolicy`) constructs this. Tests reach
  /// it via `@testable import`; production app/agent/mcp targets cannot.
  internal init(facts: [ProjectedFact]) {
    self.facts = facts
  }
}
