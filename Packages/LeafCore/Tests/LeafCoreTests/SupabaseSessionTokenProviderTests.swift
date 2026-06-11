import CryptoKit
import XCTest

@testable import LeafCore

/// AI-UI-4 — the concrete `AIInferenceAuthTokenProvider`: Supabase session →
/// fresh JWT for the relay proxy. Contract (protocol doc): MUST refresh a
/// near-expiry session (`ensureFreshSession`, never the cached
/// `currentSession()`), MUST throw when no session can be established — an
/// empty bearer is never acceptable. On pre-login dev the client bootstraps
/// the anonymous session (same trust model as every other Supabase call);
/// the account-login track later turns the no-session case into a hard
/// `.unauthorized` throw without changing this provider.
final class SupabaseSessionTokenProviderTests: XCTestCase {
  private var tempDir: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-token-provider-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    MockURLProtocol.handler = nil
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeClient(seedRefreshToken: Bool) -> SupabaseClient {
    let store = SupabaseSessionStore(at: tempDir)
    if seedRefreshToken {
      try? store.write(
        PersistedSession(
          refreshToken: "seed-rt",
          userID: "00000000-0000-0000-0000-000000000000", savedAtMs: 1))
    }
    return SupabaseClient(
      baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
      urlSession: makeURLSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32))
      },
      sessionStore: store
    )
  }

  /// Token endpoint mock returning the queued responses in order; counts hits.
  private final class TokenEndpoint: @unchecked Sendable {
    struct Issued {
      let accessToken: String
      let expiresAt: Int64
    }
    private let lock = NSLock()
    private var queue: [Issued]
    private(set) var hits = 0

    init(_ responses: [Issued]) { self.queue = responses }

    func next() -> Issued {
      lock.lock()
      defer { lock.unlock() }
      hits += 1
      return queue.count > 1 ? queue.removeFirst() : queue[0]
    }
    var hitCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return hits
    }
  }

  private func installHandler(_ endpoint: TokenEndpoint) {
    MockURLProtocol.handler = { request, _ in
      guard request.url?.path == "/auth/v1/token" else {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
      let issued = endpoint.next()
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(
          """
          { "access_token": "\(issued.accessToken)", "refresh_token": "rt-next",
            "user": { "id": "00000000-0000-0000-0000-000000000000" },
            "expires_at": \(issued.expiresAt) }
          """.utf8)
      )
    }
  }

  // No persisted session + bootstrap (anonymous signup) failing → throw,
  // never an empty bearer.
  func testFailedBootstrapThrowsNeverEmptyBearer() async {
    MockURLProtocol.handler = { request, _ in
      (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let provider = SupabaseSessionTokenProvider(client: makeClient(seedRefreshToken: false))
    do {
      _ = try await provider.currentAccessToken()
      XCTFail("expected throw when no session can be established")
    } catch {
      // Any thrown error is acceptable — the contract is "no empty bearer".
    }
  }

  // Persisted refresh token → cold-start bootstrap → the refreshed JWT.
  func testColdStartReturnsRefreshedAccessToken() async throws {
    let endpoint = TokenEndpoint([
      .init(accessToken: "jwt-fresh", expiresAt: 9_999_999_999)
    ])
    installHandler(endpoint)
    let provider = SupabaseSessionTokenProvider(client: makeClient(seedRefreshToken: true))
    let token = try await provider.currentAccessToken()
    XCTAssertEqual(token, "jwt-fresh")
    XCTAssertEqual(endpoint.hitCount, 1)
  }

  // A near-expiry session must be refreshed (ensureFreshSession), not handed
  // out from cache: bootstrap yields a JWT expiring in <60s → the provider
  // refreshes again and returns the NEW token.
  func testNearExpirySessionIsRefreshedNotCached() async throws {
    let soon = Int64(Date().timeIntervalSince1970) + 30  // inside the refresh window
    let endpoint = TokenEndpoint([
      .init(accessToken: "jwt-near-expiry", expiresAt: soon),
      .init(accessToken: "jwt-refreshed", expiresAt: 9_999_999_999),
    ])
    installHandler(endpoint)
    let provider = SupabaseSessionTokenProvider(client: makeClient(seedRefreshToken: true))
    let token = try await provider.currentAccessToken()
    XCTAssertEqual(token, "jwt-refreshed", "near-expiry JWT must be refreshed before use")
    XCTAssertEqual(endpoint.hitCount, 2)
  }

  // Second call with a still-fresh session: no extra refresh round-trip.
  func testFreshSessionIsNotRedundantlyRefreshed() async throws {
    let endpoint = TokenEndpoint([
      .init(accessToken: "jwt-fresh", expiresAt: 9_999_999_999)
    ])
    installHandler(endpoint)
    let provider = SupabaseSessionTokenProvider(client: makeClient(seedRefreshToken: true))
    _ = try await provider.currentAccessToken()
    let token = try await provider.currentAccessToken()
    XCTAssertEqual(token, "jwt-fresh")
    XCTAssertEqual(endpoint.hitCount, 1, "fresh session must not trigger another refresh")
  }
}
