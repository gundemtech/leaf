import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientNoAnonBootstrapTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"
  private var tempDir: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-noanon-\(UUID().uuidString)", isDirectory: true)
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
  private func makeJWT(pubkey: String, userID: String) -> String {
    let header = #"{"alg":"HS256","typ":"JWT"}"#
    let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
    func b64url(_ s: String) -> String {
      Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(header)).\(b64url(payload)).fake-sig"
  }

  // (a) No in-memory session, no persisted session → THROW .unauthorized.
  //     Crucially: NO call to /auth/v1/signup (anonymous bootstrap removed).
  func testEnsureAuthenticated_noSession_throwsUnauthorized_noSignup() async throws {
    let lock = NSLock()
    var paths: [String] = []
    MockURLProtocol.handler = { request, _ in
      lock.lock()
      paths.append(request.url?.path ?? "")
      lock.unlock()
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let store = SupabaseSessionStore(at: tempDir)  // empty dir → no persisted session
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
      identity: fixedIdentity(), sessionStore: store)
    do {
      _ = try await client.ensureAuthenticated()
      XCTFail("expected throw")
    } catch let error as SupabaseError {
      XCTAssertEqual(error, .unauthorized)
    }
    XCTAssertTrue(paths.isEmpty, "must NOT hit /auth/v1/signup — anonymous bootstrap removed")
  }

  // (b) Persisted refresh-token → tokenRefresh → return. No signup.
  func testEnsureAuthenticated_persistedRefresh_refreshesNoSignup() async throws {
    let userID = "00000000-0000-0000-0000-0000000000c3"
    let jwt = makeJWT(pubkey: String(repeating: "42", count: 32), userID: userID)
    let store = SupabaseSessionStore(at: tempDir)
    try store.write(PersistedSession(refreshToken: "persisted-rt", userID: userID, savedAtMs: 1))
    let lock = NSLock()
    var paths: [String] = []
    MockURLProtocol.handler = { request, _ in
      lock.lock()
      paths.append(request.url?.path ?? "")
      lock.unlock()
      XCTAssertEqual(request.url?.path, "/auth/v1/token")
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        """
        { "access_token": "\(jwt)", "refresh_token": "rotated-rt",
          "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
        """.data(using: .utf8)!
      )
    }
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
      identity: fixedIdentity(), sessionStore: store)
    let session = try await client.ensureAuthenticated()
    XCTAssertEqual(session.refreshToken, "rotated-rt")
    XCTAssertEqual(paths, ["/auth/v1/token"])
  }

  // (c) After login (in-memory session present), ensureAuthenticatedAndPubkeyRegistered
  //     runs registerPubkey → tokenRefresh, and the refreshed JWT carries pubkey claim.
  func testEnsureAuthenticatedAndPubkeyRegistered_postLogin_registerThenRefresh() async throws {
    let userID = "00000000-0000-0000-0000-0000000000d4"
    let expectedPubkey = String(repeating: "42", count: 32)
    let refreshedJWT = makeJWT(pubkey: expectedPubkey, userID: userID)
    let lock = NSLock()
    var paths: [String] = []
    MockURLProtocol.handler = { request, _ in
      lock.lock()
      paths.append(request.url?.path ?? "")
      lock.unlock()
      switch request.url?.path {
      case "/auth/v1/token" where (request.url?.query ?? "").contains("grant_type=password"):
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "tok-login", "refresh_token": "ref-login",
            "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      case "/functions/v1/register_pubkey":
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-login")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"ok":true}"#.utf8)
        )
      case "/auth/v1/token":  // refresh (grant_type=refresh_token)
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "\(refreshedJWT)", "refresh_token": "ref-final",
            "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      default:
        XCTFail("unexpected \(request.url?.absoluteString ?? "")")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
    let store = SupabaseSessionStore(at: tempDir)
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
      identity: fixedIdentity(), sessionStore: store)
    // Simulate a completed login (installs in-memory session).
    _ = try await client.signInWithPassword(email: "a@b.co", password: "pw", captchaToken: "c")
    let session = try await client.ensureAuthenticatedAndPubkeyRegistered()
    XCTAssertEqual(session.accessToken, refreshedJWT)
    XCTAssertEqual(session.pubkeyClaim, expectedPubkey)
    XCTAssertEqual(
      paths,
      ["/auth/v1/token", "/functions/v1/register_pubkey", "/auth/v1/token"])
  }
}
