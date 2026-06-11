import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientAccountTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"
  private var tempDir: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-acct-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }
  override func tearDown() async throws {
    MockURLProtocol.handler = nil
    try? FileManager.default.removeItem(at: tempDir)
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
  /// Client with a persisted refresh token; the handler answers the refresh and
  /// then the account call.
  private func makeClient() throws -> SupabaseClient {
    let store = SupabaseSessionStore(at: tempDir)
    try store.write(
      PersistedSession(
        refreshToken: "rt", userID: "00000000-0000-0000-0000-0000000000a1", savedAtMs: 1))
    return SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
      identity: fixedIdentity(), sessionStore: store)
  }
  private func okRefresh(_ request: URLRequest) -> (HTTPURLResponse, Data) {
    (
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      """
      { "access_token": "fresh-tok", "refresh_token": "rt2",
        "user": { "id": "00000000-0000-0000-0000-0000000000a1" }, "expires_at": 9999999999 }
      """.data(using: .utf8)!
    )
  }

  func testFetchUserProfile_decodesAndSendsBearer() async throws {
    let lock = NSLock()
    var sawAuth: String?
    MockURLProtocol.handler = { request, _ in
      if request.url?.path == "/auth/v1/user" {
        lock.lock()
        sawAuth = request.value(forHTTPHeaderField: "Authorization")
        lock.unlock()
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "id": "00000000-0000-0000-0000-0000000000a1", "email": "a@b.co",
            "created_at": "2024-06-10T00:00:00.000Z",
            "app_metadata": { "provider": "github" },
            "user_metadata": { "full_name": "A B" } }
          """.data(using: .utf8)!
        )
      }
      return self.okRefresh(request)  // /auth/v1/token refresh
    }
    let client = try makeClient()
    let profile = try await client.fetchUserProfile()
    XCTAssertEqual(profile.email, "a@b.co")
    XCTAssertEqual(profile.provider, "github")
    XCTAssertEqual(profile.fullName, "A B")
    XCTAssertEqual(sawAuth, "Bearer fresh-tok")
  }

  func testFetchUserProfile_non2xx_throws() async throws {
    MockURLProtocol.handler = { request, _ in
      if request.url?.path == "/auth/v1/user" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
          Data(#"{"msg":"bad"}"#.utf8)
        )
      }
      return self.okRefresh(request)
    }
    let client = try makeClient()
    do {
      _ = try await client.fetchUserProfile()
      XCTFail("expected throw")
    } catch is SupabaseError { /* expected */  }
  }

  func testDeleteSelfAccount_postsRPCWithBearer_succeedsOn204() async throws {
    let lock = NSLock()
    var sawPath: String?
    var sawAuth: String?
    MockURLProtocol.handler = { request, _ in
      if request.url?.path == "/rest/v1/rpc/delete_self_account" {
        lock.lock()
        sawPath = request.url?.path
        sawAuth = request.value(forHTTPHeaderField: "Authorization")
        lock.unlock()
        return (
          HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
      return self.okRefresh(request)
    }
    let client = try makeClient()
    try await client.deleteSelfAccount()
    XCTAssertEqual(sawPath, "/rest/v1/rpc/delete_self_account")
    XCTAssertEqual(sawAuth, "Bearer fresh-tok")
  }

  func testDeleteSelfAccount_non2xx_throws() async throws {
    MockURLProtocol.handler = { request, _ in
      if request.url?.path == "/rest/v1/rpc/delete_self_account" {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
          Data(#"{"message":"function not found"}"#.utf8)
        )
      }
      return self.okRefresh(request)
    }
    let client = try makeClient()
    do {
      try await client.deleteSelfAccount()
      XCTFail("expected throw")
    } catch is SupabaseError { /* expected */  }
  }
}
