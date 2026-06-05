import XCTest

@testable import LeafCore

final class AIWorkAnswererTests: XCTestCase {
  private let policy = LLMPolicy()

  private func events(_ payload: [String: String]) -> [EgressEvent] {
    [
      EgressEvent(
        timestamp: Date(timeIntervalSince1970: 1), kind: "issue_updated", bundleID: nil,
        payload: payload)
    ]
  }

  private struct StubSummarizer: Summarizer {
    let result: Result<String, SummarizerError>
    func summarize(_ context: PromptSafeContext, model: SummarizerModel, maxTokens: Int)
      async throws -> SummarizerOutput
    {
      switch result {
      case .success(let t):
        return SummarizerOutput(
          text: t, usage: TokenUsage(inputTokens: 1, outputTokens: 1),
          modelUsed: model.apiModelID, stopReason: nil)
      case .failure(let e):
        throw e
      }
    }
  }

  // A body-only event projects to nothing → notEnoughData, and the summarizer is
  // never called (the stub would throw if it were).
  func testEmptyFactsShortCircuitsBeforeLLM() async {
    let answerer = AIWorkAnswerer(
      policy: policy,
      summarizer: StubSummarizer(result: .failure(.network("must-not-be-called"))),
      modelGate: DefaultModelGate())
    let a = await answerer.answer(question: "q", events: events(["body": "only a body"]))
    XCTAssertEqual(a, .notEnoughData)
  }

  func testSuccessReturnsText() async {
    let answerer = AIWorkAnswerer(
      policy: policy, summarizer: StubSummarizer(result: .success("your week summary")),
      modelGate: DefaultModelGate())
    let a = await answerer.answer(question: "q", events: events(["additions": "5"]))
    XCTAssertEqual(a, .text("your week summary"))
  }

  func testMissingKeyMapsToFriendlyFailure() async {
    let answerer = AIWorkAnswerer(
      policy: policy, summarizer: StubSummarizer(result: .failure(.missingAPIKey)),
      modelGate: DefaultModelGate())
    let a = await answerer.answer(question: "q", events: events(["additions": "5"]))
    guard case .failure(let m) = a else { return XCTFail("expected failure") }
    XCTAssertTrue(m.contains("API key"))
  }

  // Error messages are opaque — never echo provider/key/body detail (§8.1).
  func testErrorMessagesAreOpaque() {
    XCTAssertFalse(AIWorkAnswerer.message(for: .decode("decode-failed")).contains("decode-failed"))
    XCTAssertFalse(
      AIWorkAnswerer.message(for: .authFailed("invalid key sk-secret")).contains("sk-secret"))
    XCTAssertFalse(
      AIWorkAnswerer.message(for: .network("socket 1.2.3.4")).contains("1.2.3.4"))
  }
}
