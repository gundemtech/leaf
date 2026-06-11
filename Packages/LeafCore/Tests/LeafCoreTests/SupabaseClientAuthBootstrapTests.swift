import CryptoKit
import XCTest

@testable import LeafCore

// Phase 1 (account-login) — the anonymous-bootstrap behaviour this suite used
// to cover has been removed from SupabaseClient (no more
// performSignInAnonymously / signup→register→refresh on a fresh device).
// The replacement no-anonymous contract lives in
// SupabaseClientNoAnonBootstrapTests. The class shell + helpers are kept so the
// test target stays stable.
final class SupabaseClientAuthBootstrapTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"

  override func tearDown() async throws {
    MockURLProtocol.handler = nil
  }

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func fixedIdentity() -> @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey {
    let bytes = Data(repeating: 0x42, count: 32)
    return { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
  }
}
