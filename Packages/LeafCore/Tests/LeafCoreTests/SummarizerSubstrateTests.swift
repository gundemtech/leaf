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
}
