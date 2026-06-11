import Foundation

/// AI-UI-4 — per-call inference-path routing for the in-app AI surfaces.
/// BYOK valve semantics (AI Coworker canon: pool + BYOK valve): a configured
/// Anthropic key always wins; without one the surface rides the team pool
/// (`.aiIncluded` → RelayProxySummarizer behind the moat seam). Resolution
/// happens per call so adding/removing the key in Settings flips the very
/// next request — no reader reconstruction, no app restart.
public struct AIBackendRouter: Sendable {
  public struct Resolution: Sendable {
    public let summarizer: any Summarizer
    public let path: InferencePath

    public init(summarizer: any Summarizer, path: InferencePath) {
      self.summarizer = summarizer
      self.path = path
    }
  }

  private let keyStore: any AnthropicKeyStore
  private let byok: AISummarizerMoat
  private let included: AISummarizerMoat

  public init(keyStore: any AnthropicKeyStore, byok: AISummarizerMoat, included: AISummarizerMoat) {
    self.keyStore = keyStore
    self.byok = byok
    self.included = included
  }

  /// Key present → (byok, .byok). Absent, blank, or unreadable (a Keychain/
  /// file read failure must not brick AI) → (included, .aiIncluded).
  public func resolve() -> Resolution {
    let key = (try? keyStore.loadKey()) ?? nil
    let hasKey = key.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    return hasKey
      ? Resolution(summarizer: byok.summarizer, path: .byok)
      : Resolution(summarizer: included.summarizer, path: .aiIncluded)
  }
}
