import CryptoKit
import XCTest

@testable import LeafCore

/// Phase 1 (account-login) — the native macOS app does NOT send a captcha
/// token (global Supabase CAPTCHA protection is OFF). This asserts that calling
/// `signInWithPassword(email:password:)` with no token produces a request body
/// WITHOUT a `gotrue_meta_security` key, and still returns the session. The
/// captcha-on path stays covered by `SupabaseClientPasswordLoginTests`.
final class SupabaseClientPasswordLoginNoCaptchaTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"

  override func tearDown() async throws { MockURLProtocol.handler = nil }

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func fixedIdentity() -> @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey {
    let bytes = Data(repeating: 0x42, count: 32)
    return { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
  }

  func testSignInWithPassword_noCaptcha_omitsMetaSecurity_returnsSession() async throws {
    MockURLProtocol.handler = { request, body in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://test.supabase.co/auth/v1/token?grant_type=password")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
      // Body carries email + password but NO gotrue_meta_security key.
      let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
      XCTAssertEqual(json["email"] as? String, "a@b.co")
      XCTAssertEqual(json["password"] as? String, "pw123")
      XCTAssertNil(
        json["gotrue_meta_security"],
        "native app must NOT send a captcha token (global CAPTCHA is off)")
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let out = """
        { "access_token": "tok-nocap", "refresh_token": "ref-nocap",
          "user": { "id": "00000000-0000-0000-0000-0000000000a2" },
          "expires_at": 9999999999 }
        """.data(using: .utf8)!
      return (resp, out)
    }
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(), identity: fixedIdentity())
    let session = try await client.signInWithPassword(email: "a@b.co", password: "pw123")
    XCTAssertEqual(session.accessToken, "tok-nocap")
    XCTAssertEqual(session.refreshToken, "ref-nocap")
  }
}
