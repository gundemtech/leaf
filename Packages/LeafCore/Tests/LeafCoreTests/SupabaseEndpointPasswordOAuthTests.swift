import XCTest

@testable import LeafCore

final class SupabaseEndpointPasswordOAuthTests: XCTestCase {
  private let baseURL = URL(string: "https://jwxnhwyqjzjmjnmwpwyq.supabase.co")!

  func testSignInWithPasswordURL() {
    let url = SupabaseEndpoint.signInWithPassword(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/auth/v1/token?grant_type=password")
  }

  func testSignUpWithPasswordURL() {
    let url = SupabaseEndpoint.signUpWithPassword(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/auth/v1/signup")
  }

  func testOAuthTokenURL() {
    let url = SupabaseEndpoint.oauthToken(baseURL: baseURL)
    XCTAssertEqual(
      url.absoluteString,
      "https://jwxnhwyqjzjmjnmwpwyq.supabase.co/auth/v1/token?grant_type=pkce")
  }

  func testOAuthAuthorizeURL_google() {
    let url = SupabaseEndpoint.oauthAuthorize(
      baseURL: baseURL, provider: "google",
      redirectTo: "http://127.0.0.1:47825/callback", codeChallenge: "abc123")
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    XCTAssertEqual(comps.path, "/auth/v1/authorize")
    let items = Dictionary(
      uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
    XCTAssertEqual(items["provider"], "google")
    XCTAssertEqual(items["redirect_to"], "http://127.0.0.1:47825/callback")
    XCTAssertEqual(items["code_challenge"], "abc123")
    XCTAssertEqual(items["code_challenge_method"], "s256")
    // GoTrue brokers the flow and owns the provider-leg state — sending a
    // caller `state` breaks it with bad_oauth_state. Guard against re-adding.
    XCTAssertNil(items["state"], "must NOT send a caller state to GoTrue /authorize")
  }
}
