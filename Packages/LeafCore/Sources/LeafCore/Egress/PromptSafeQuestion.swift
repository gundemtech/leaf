import Foundation

/// The user's own natural-language question, wrapped for the Q&A path. It mirrors
/// `PromptSafeContext` opacity (no public init — sole construction is
/// `LLMPolicy.makeQuestion`) so a caller cannot smuggle un-vetted event text into
/// the "question" slot. The question is the user's OWN input (not corpus-derived),
/// so it is not run through `FactProjection`; `makeQuestion` only normalizes it
/// (collapse whitespace/control chars → single segment, then cap) so it can never
/// forge a `Facts:` header in the rendered prompt (Track AI Coworker §8.3, N-4).
public struct PromptSafeQuestion: Sendable, Equatable {
  public let text: String

  internal init(text: String) {
    self.text = text
  }
}
