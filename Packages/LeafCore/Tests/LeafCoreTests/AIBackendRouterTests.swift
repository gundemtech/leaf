import XCTest

@testable import LeafCore

/// AI-UI-4 — BYOK valve: key present → (byok, .byok); absent / unreadable /
/// blank → (included, .aiIncluded). Resolution is per-call so a key added or
/// removed in Settings takes effect on the next ask without an app restart.
final class AIBackendRouterTests: XCTestCase {

  /// Class-based fake so resolutions are identity-comparable.
  private final class TaggedSummarizer: Summarizer {
    func summarize(_ context: PromptSafeContext, model: SummarizerModel, maxTokens: Int)
      async throws -> SummarizerOutput
    {
      throw SummarizerError.network("fake")
    }
  }

  /// Mutable in-memory key store — flips state between resolve() calls.
  private final class FakeKeyStore: AnthropicKeyStore, @unchecked Sendable {
    var key: String?
    var loadError: Error?
    init(key: String? = nil, loadError: Error? = nil) {
      self.key = key
      self.loadError = loadError
    }
    func loadKey() throws -> String? {
      if let loadError { throw loadError }
      return key
    }
    func storeKey(_ key: String) throws { self.key = key }
    func deleteKey() throws { key = nil }
  }

  private let byokSummarizer = TaggedSummarizer()
  private let includedSummarizer = TaggedSummarizer()

  private func router(_ store: FakeKeyStore) -> AIBackendRouter {
    AIBackendRouter(
      keyStore: store,
      byok: AISummarizerMoat(summarizer: byokSummarizer),
      included: AISummarizerMoat(summarizer: includedSummarizer))
  }

  func testKeyPresentResolvesByok() {
    let r = router(FakeKeyStore(key: "sk-ant-test")).resolve()
    XCTAssertEqual(r.path, .byok)
    XCTAssertTrue((r.summarizer as AnyObject) === byokSummarizer)
  }

  func testNoKeyResolvesIncluded() {
    let r = router(FakeKeyStore(key: nil)).resolve()
    XCTAssertEqual(r.path, .aiIncluded)
    XCTAssertTrue((r.summarizer as AnyObject) === includedSummarizer)
  }

  // A Keychain/file read failure must not brick AI — fall back to the pool.
  func testThrowingKeyStoreResolvesIncluded() {
    let r = router(FakeKeyStore(loadError: LeafError.keychainUnavailable(-1))).resolve()
    XCTAssertEqual(r.path, .aiIncluded)
    XCTAssertTrue((r.summarizer as AnyObject) === includedSummarizer)
  }

  // A stored-but-blank key is not a key.
  func testBlankKeyResolvesIncluded() {
    let r = router(FakeKeyStore(key: "   \n")).resolve()
    XCTAssertEqual(r.path, .aiIncluded)
  }

  // Per-call resolution — the valve flips without reconstructing the router.
  func testResolveIsPerCall() {
    let store = FakeKeyStore(key: nil)
    let router = router(store)
    XCTAssertEqual(router.resolve().path, .aiIncluded)
    store.key = "sk-ant-added-later"
    XCTAssertEqual(router.resolve().path, .byok)
    store.key = nil
    XCTAssertEqual(router.resolve().path, .aiIncluded)
  }
}
