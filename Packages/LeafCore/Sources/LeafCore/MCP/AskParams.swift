import Foundation

/// Track AI Coworker P1 — argument decoder for the `ask_about_my_work` MCP tool.
/// In LeafCore (not LeafMCP) so SPM tests cover the parsing branches without
/// xcodebuild, mirroring `D3ToolParams`. Pure / Sendable; produces a typed value
/// or a human-readable error surfaced as `MCPProtocolError.invalidParams`.
public enum AskParams {
  public struct Request: Sendable, Equatable {
    public let question: String
    public let period: ReviewActivityInsights.ReviewActivityPeriod
    public let preferredModel: SummarizerModel?

    public init(
      question: String,
      period: ReviewActivityInsights.ReviewActivityPeriod,
      preferredModel: SummarizerModel?
    ) {
      self.question = question
      self.period = period
      self.preferredModel = preferredModel
    }
  }

  /// Decode `{question: string, period?: today|yesterday|last_7_days,
  /// model?: haiku|sonnet|opus}`.
  public static func decode(arguments: Any?) -> D3ToolParams.Decoded<Request> {
    guard let dict = arguments as? [String: Any] else {
      return .error(
        "ask_about_my_work requires {question: string, period?: today|yesterday|last_7_days, model?: haiku|sonnet|opus}"
      )
    }
    guard
      let question = (dict["question"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !question.isEmpty
    else {
      return .error("missing required 'question' string")
    }

    let period: ReviewActivityInsights.ReviewActivityPeriod
    if let raw = dict["period"] as? String {
      guard let p = ReviewActivityInsights.ReviewActivityPeriod(rawValue: raw) else {
        return .error("period must be one of: today, yesterday, last_7_days")
      }
      period = p
    } else {
      period = .today
    }

    var preferred: SummarizerModel? = nil
    if let raw = dict["model"] as? String {
      guard let m = SummarizerModel(rawValue: raw) else {
        return .error("model must be one of: haiku, sonnet, opus")
      }
      preferred = m
    }

    return .ok(Request(question: question, period: period, preferredModel: preferred))
  }
}
