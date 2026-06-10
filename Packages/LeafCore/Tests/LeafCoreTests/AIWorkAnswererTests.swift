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

  // MARK: - AI-UI-4 — path-aware messages

  // Team pool exhausted → honest copy: the valve out is the user's own key.
  func testBudgetExhaustedOnIncludedPathSuggestsOwnKey() {
    let m = AIWorkAnswerer.message(for: .budgetExhausted(retryAfter: nil), path: .aiIncluded)
    XCTAssertTrue(m.localizedCaseInsensitiveContains("your own Anthropic key"))
    XCTAssertTrue(m.contains("Settings"))
  }

  // On the included path there is no user-owned Anthropic key to blame.
  func testAuthFailedOnIncludedPathDoesNotBlameAnthropicKey() {
    let m = AIWorkAnswerer.message(for: .authFailed("x"), path: .aiIncluded)
    XCTAssertFalse(m.contains("Anthropic API key"))
    XCTAssertTrue(m.contains("Leaf account"))
  }

  // BYOK copy is the pre-AI-UI-4 wording — no regression for key users.
  func testByokMessagesUnchanged() {
    XCTAssertEqual(
      AIWorkAnswerer.message(for: .missingAPIKey, path: .byok),
      "No Anthropic API key configured. Add your key to enable AI answers.")
    XCTAssertEqual(
      AIWorkAnswerer.message(for: .authFailed("x"), path: .byok),
      "Your Anthropic API key was rejected (invalid or revoked). Update it and try again.")
    XCTAssertEqual(
      AIWorkAnswerer.message(for: .budgetExhausted(retryAfter: nil), path: .byok),
      "AI inference budget exhausted. Try again later.")
  }

  // One-arg forward keeps every existing call-site on BYOK semantics.
  func testOneArgMessageForwardsToByok() {
    XCTAssertEqual(
      AIWorkAnswerer.message(for: .authFailed("x")),
      AIWorkAnswerer.message(for: .authFailed("x"), path: .byok))
  }

  func testPathAwareMessagesAreOpaque() {
    XCTAssertFalse(
      AIWorkAnswerer.message(for: .authFailed("jwt eyJ-secret"), path: .aiIncluded)
        .contains("eyJ-secret"))
  }

  // MARK: - AI-UI-4 — AIFailure kinds + Settings CTA

  func testFailureKindTotalMapping() {
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .missingAPIKey), .missingKey)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .authFailed("x")), .auth)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .budgetExhausted(retryAfter: 30)), .budget)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .rateLimited(retryAfter: 5)), .rateLimited)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .attestationFailed("m")), .attestation)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .contextEmpty), .transient)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .badRequest("b")), .transient)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .serverError(503)), .transient)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .network("n")), .transient)
    XCTAssertEqual(AIWorkAnswerer.failureKind(for: .decode("d")), .transient)
  }

  func testFailureBundlesKindAndPathAwareMessage() {
    let f = AIWorkAnswerer.failure(for: .budgetExhausted(retryAfter: nil), path: .aiIncluded)
    XCTAssertEqual(f.kind, .budget)
    XCTAssertEqual(
      f.message, AIWorkAnswerer.message(for: .budgetExhausted(retryAfter: nil), path: .aiIncluded))
  }

  // CTA truth table: only the two failures the user can fix in Settings →
  // AI Answers earn the button.
  func testShowsSettingsCTATruthTable() {
    XCTAssertTrue(AIFailure(kind: .missingKey, message: "m").showsSettingsCTA)
    XCTAssertTrue(AIFailure(kind: .budget, message: "m").showsSettingsCTA)
    XCTAssertFalse(AIFailure(kind: .auth, message: "m").showsSettingsCTA)
    XCTAssertFalse(AIFailure(kind: .rateLimited, message: "m").showsSettingsCTA)
    XCTAssertFalse(AIFailure(kind: .attestation, message: "m").showsSettingsCTA)
    XCTAssertFalse(AIFailure(kind: .auditWrite, message: "m").showsSettingsCTA)
    XCTAssertFalse(AIFailure(kind: .localRead, message: "m").showsSettingsCTA)
    XCTAssertFalse(AIFailure(kind: .transient, message: "m").showsSettingsCTA)
  }
}
