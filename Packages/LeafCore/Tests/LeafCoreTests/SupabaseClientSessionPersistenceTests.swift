// Phase Track-5 S4 — SupabaseClient sessionStore load-on-bootstrap coverage.
// Closes S3 carry-over I3 (refresh_token persistence).
//
// Phase 1 (account-login) — the anonymous-bootstrap tests
// (FreshSignupAndPersist / FallsThroughToFreshSignup /
// RegisterPubkeyFails409 / NoSessionStore_BackwardsCompatible) were removed
// here: ensureAuthenticated no longer falls back to anonymous signup. The
// no-session-throws and post-login-register paths are covered by
// SupabaseClientNoAnonBootstrapTests. The persisted-refresh-then-return
// contract below is unchanged and still holds.

import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientSessionPersistenceTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"
  private var tempDir: URL!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-supabase-bootstrap-\(UUID().uuidString)", isDirectory: true)
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

  // MARK: - Second launch — persisted session → token refresh shortcut, no signup

  func testSecondLaunch_PersistedSession_UsesTokenRefresh_NoSignup() async throws {
    let pubkey = String(repeating: "42", count: 32)
    let userID = "00000000-0000-0000-0000-000000000bbb"
    let jwt = makeJWT(pubkey: pubkey, userID: userID)

    // Pre-write persisted session.
    let store = SupabaseSessionStore(at: tempDir)
    try store.write(PersistedSession(refreshToken: "old-rt", userID: userID, savedAtMs: 1_000))

    let lock = NSLock()
    var paths: [String] = []
    MockURLProtocol.handler = { request, _ in
      lock.lock()
      paths.append(request.url?.path ?? "")
      lock.unlock()
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/token":
        // Verify refresh_token came from persisted session.
        let body = request.httpBody ?? request.bodyStreamAsData()
        let bodyStr = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("old-rt"), "expected old-rt in body, got: \(bodyStr)")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "\(jwt)", "refresh_token": "new-rt",
            "user": { "id": "\(userID)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      default:
        XCTFail("unexpected path \(path) — should ONLY hit /auth/v1/token")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }

    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey,
      urlSession: makeSession(),
      identity: fixedIdentity(),
      sessionStore: store
    )
    let session = try await client.ensureAuthenticated()
    XCTAssertEqual(session.refreshToken, "new-rt")
    XCTAssertEqual(session.pubkeyClaim, pubkey)

    // Only token endpoint hit; no signup / register.
    XCTAssertEqual(paths, ["/auth/v1/token"])

    // Persisted session updated to new refresh_token.
    let persisted = try store.read()
    XCTAssertEqual(persisted?.refreshToken, "new-rt")
  }
}

// Helper for capturing body from URLRequest streams (MockURLProtocol scenarios where
// httpBody is consumed and only bodyStream remains).
extension URLRequest {
  fileprivate func bodyStreamAsData() -> Data {
    guard let stream = httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufSize = 1024
    var buf = [UInt8](repeating: 0, count: bufSize)
    while stream.hasBytesAvailable {
      let read = stream.read(&buf, maxLength: bufSize)
      if read <= 0 { break }
      data.append(buf, count: read)
    }
    return data
  }
}
