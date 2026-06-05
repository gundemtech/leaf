import XCTest

@testable import LeafCore

final class SummarizerSubstrateTests: XCTestCase {
  func testModelAPIIDMapping() {
    XCTAssertEqual(SummarizerModel.haiku.apiModelID, "claude-haiku-4-5")
    XCTAssertEqual(SummarizerModel.sonnet.apiModelID, "claude-sonnet-4-6")
    XCTAssertEqual(SummarizerModel.opus.apiModelID, "claude-opus-4-8")
  }

  func testDefaultModelIsHaiku() {
    XCTAssertEqual(SummarizerModel.default, .haiku)
    XCTAssertEqual(SummarizerModel.allCases.count, 3)
  }

  func testPublicSubstrateThrowsMissingAPIKey() async {
    let ctx = LLMPolicy().makeContext(events: [])
    do {
      _ = try await AISummarizerMoat.publicSubstrate.summarizer.summarize(
        ctx, model: .haiku, maxTokens: 1024)
      XCTFail("no-op substrate must throw")
    } catch {
      XCTAssertEqual(error as? SummarizerError, .missingAPIKey)
    }
  }

  func testBudgetExhaustedEquatable() {
    XCTAssertEqual(
      SummarizerError.budgetExhausted(retryAfter: 5),
      SummarizerError.budgetExhausted(retryAfter: 5))
    XCTAssertNotEqual(
      SummarizerError.budgetExhausted(retryAfter: 5),
      SummarizerError.budgetExhausted(retryAfter: nil))
    XCTAssertNotEqual(
      SummarizerError.budgetExhausted(retryAfter: nil),
      SummarizerError.rateLimited(retryAfter: nil))
  }

  func testFakeSummarizerProvesSeamCallable() async throws {
    struct FakeSummarizer: Summarizer {
      func summarize(_ context: PromptSafeContext, model: SummarizerModel, maxTokens: Int)
        async throws -> SummarizerOutput
      {
        SummarizerOutput(
          text: "ok", usage: TokenUsage(inputTokens: 1, outputTokens: 1),
          modelUsed: model.apiModelID, stopReason: "end_turn")
      }
    }
    let ctx = LLMPolicy().makeContext(events: [])
    let out = try await FakeSummarizer().summarize(ctx, model: .sonnet, maxTokens: 256)
    XCTAssertEqual(out.text, "ok")
    XCTAssertEqual(out.modelUsed, "claude-sonnet-4-6")
  }

  // P3 — the escalation overload's fail-safe default must forward to the base
  // method WITHOUT exposing bodies to a backend that did not opt in (never a leak).
  func testEscalationOverloadFailSafeDefaultDropsBodies() async throws {
    struct BaseOnly: Summarizer {
      func summarize(_ context: PromptSafeContext, model: SummarizerModel, maxTokens: Int)
        async throws -> SummarizerOutput
      {
        SummarizerOutput(
          text: "base", usage: TokenUsage(inputTokens: 1, outputTokens: 1),
          modelUsed: model.apiModelID, stopReason: nil)
      }
    }
    let ctx = LLMPolicy().makeContext(events: [])
    let escalated = LLMPolicy().makeEscalation(selected: [
      EgressEvent(
        timestamp: Date(timeIntervalSince1970: 1), kind: "gh_pr_opened", bundleID: nil,
        payload: ["body": "SENTINEL-BODY"])
    ])
    let q = LLMPolicy().makeQuestion("hi")
    let out = try await BaseOnly().summarize(
      ctx, question: q, escalated: escalated, model: .haiku, maxTokens: 64)
    XCTAssertEqual(out.text, "base", "fail-safe default forwarded to base; bodies never reached the backend")
  }

  func testSubstrateEscalationThrowsMissingAPIKey() async {
    let ctx = LLMPolicy().makeContext(events: [])
    let escalated = LLMPolicy().makeEscalation(selected: [])
    let q = LLMPolicy().makeQuestion("hi")
    do {
      _ = try await AISummarizerMoat.publicSubstrate.summarizer.summarize(
        ctx, question: q, escalated: escalated, model: .haiku, maxTokens: 64)
      XCTFail("no-op substrate must throw")
    } catch {
      XCTAssertEqual(error as? SummarizerError, .missingAPIKey)
    }
  }
}
