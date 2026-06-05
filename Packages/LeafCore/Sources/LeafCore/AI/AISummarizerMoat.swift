import Foundation

/// Public-substrate summarizer — ships zero inference. Throws `missingAPIKey`
/// so "no LLM wired" is unambiguous (mirrors `NoOp*` detector substrate).
public struct NoOpSummarizer: Summarizer {
  public init() {}
  public func summarize(
    _ context: PromptSafeContext,
    model: SummarizerModel,
    maxTokens: Int
  ) async throws -> SummarizerOutput {
    throw SummarizerError.missingAPIKey
  }
}

/// Injection seam for the prod `Summarizer` (mirrors `DetectorMoat`). The real
/// BYOK-Anthropic backend lives in `LeafCorePrivate` (`prodAISummarizerMoat`);
/// CI/substrate builds use `publicSubstrate` (no-op).
public struct AISummarizerMoat: Sendable {
  public let summarizer: any Summarizer
  public init(summarizer: any Summarizer) {
    self.summarizer = summarizer
  }

  public static let publicSubstrate = AISummarizerMoat(summarizer: NoOpSummarizer())
}
