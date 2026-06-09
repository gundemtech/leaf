import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientPasswordLoginTests: XCTestCase {
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

  func testSignInWithPassword_success_returnsSession_andSendsCaptchaToken() async throws {
    MockURLProtocol.handler = { request, body in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://test.supabase.co/auth/v1/token?grant_type=password")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-anon-key")
      // Body carries email, password, and gotrue_meta_security.captcha_token.
      let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
      XCTAssertEqual(json["email"] as? String, "a@b.co")
      XCTAssertEqual(json["password"] as? String, "pw123")
      let meta = json["gotrue_meta_security"] as? [String: Any]
      XCTAssertEqual(meta?["captcha_token"] as? String, "cap-tok")
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let out = """
        { "access_token": "tok-pw", "refresh_token": "ref-pw",
          "user": { "id": "00000000-0000-0000-0000-0000000000a1" },
          "expires_at": 9999999999 }
        """.data(using: .utf8)!
      return (resp, out)
    }
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(), identity: fixedIdentity())
    let session = try await client.signInWithPassword(
      email: "a@b.co", password: "pw123", captchaToken: "cap-tok")
    XCTAssertEqual(session.accessToken, "tok-pw")
    XCTAssertEqual(session.refreshToken, "ref-pw")
  }

  func testSignInWithPassword_400_throwsBadRequest() async throws {
    MockURLProtocol.handler = { request, _ in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
      return (resp, Data(#"{"error":"invalid_grant"}"#.utf8))
    }
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(), identity: fixedIdentity())
    do {
      _ = try await client.signInWithPassword(
        email: "a@b.co", password: "wrong", captchaToken: "cap-tok")
      XCTFail("expected throw")
    } catch let error as SupabaseError {
      XCTAssertEqual(error, .badRequest)
    }
  }
}
