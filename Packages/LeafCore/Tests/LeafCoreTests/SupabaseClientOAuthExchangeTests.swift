import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientOAuthExchangeTests: XCTestCase {
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

  func testExchangeOAuthCode_success_sendsPKCEBody_noCaptcha() async throws {
    MockURLProtocol.handler = { request, body in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://test.supabase.co/auth/v1/token?grant_type=pkce")
      let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
      XCTAssertEqual(json["auth_code"] as? String, "the-code")
      XCTAssertEqual(json["code_verifier"] as? String, "the-verifier")
      XCTAssertNil(json["gotrue_meta_security"], "OAuth path must NOT send a captcha token")
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let out = """
        { "access_token": "tok-oauth", "refresh_token": "ref-oauth",
          "user": { "id": "00000000-0000-0000-0000-0000000000b2" },
          "expires_at": 9999999999 }
        """.data(using: .utf8)!
      return (resp, out)
    }
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(), identity: fixedIdentity())
    let session = try await client.exchangeOAuthCode(
      code: "the-code", codeVerifier: "the-verifier", redirectURI: "leaf://auth/callback")
    XCTAssertEqual(session.accessToken, "tok-oauth")
    XCTAssertEqual(session.refreshToken, "ref-oauth")
  }

  func testExchangeOAuthCode_400_throwsBadRequest() async throws {
    MockURLProtocol.handler = { request, _ in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
      return (resp, Data(#"{"error":"invalid_request"}"#.utf8))
    }
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(), identity: fixedIdentity())
    do {
      _ = try await client.exchangeOAuthCode(
        code: "bad", codeVerifier: "v", redirectURI: "leaf://auth/callback")
      XCTFail("expected throw")
    } catch let error as SupabaseError {
      XCTAssertEqual(error, .badRequest)
    }
  }
}
