//
//  SupabaseClientRetryTests.swift
//  LeafCoreTests
//
//  Phase M-I (optimization-tier-m.md). Coverage:
//  - Pure classifier (9 tests, no actor, no URLSession)
//  - performHTTP integration via MockURLProtocol (added in Task 2 / Task 3)
//

import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientRetryTests: XCTestCase {
  // MARK: - Pure classifier

  private let policy = RetryPolicy(
    maxAttempts: 4,
    delays: [.milliseconds(200), .seconds(1), .seconds(3)],
    jitterFraction: 0.25
  )

  private func makeResp(_ status: Int, url: URL = URL(string: "https://t.example/x")!)
    -> HTTPURLResponse
  {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
  }

  func test_classifier_giveUp_when_attempt_at_max() {
    let d = classify(
      response: makeResp(503), error: nil, attempt: 3, policy: policy,
      retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
    )
    XCTAssertEqual(d, .giveUp)
  }

  func test_classifier_retries_5xx_with_schedule_delay() {
    for status in [500, 502, 503, 504, 505, 506, 507, 508, 510, 511] {
      let d = classify(
        response: makeResp(status), error: nil, attempt: 0, policy: policy,
        retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
      )
      XCTAssertEqual(d, .retry(after: .milliseconds(200)), "status=\(status)")
    }
  }

  func test_classifier_giveUp_on_501_not_implemented() {
    let d = classify(
      response: makeResp(501), error: nil, attempt: 0, policy: policy,
      retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
    )
    XCTAssertEqual(d, .giveUp)
  }

  func test_classifier_429_with_retryAfterHint_uses_hint() {
    let d = classify(
      response: makeResp(429), error: nil, attempt: 0, policy: policy,
      retryAfterHint: .seconds(2), nextDelayJitterMultiplier: 1.0
    )
    XCTAssertEqual(d, .retry(after: .seconds(2)))
  }

  func test_classifier_429_without_hint_uses_schedule() {
    let d = classify(
      response: makeResp(429), error: nil, attempt: 1, policy: policy,
      retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
    )
    XCTAssertEqual(d, .retry(after: .seconds(1)))  // schedule[1] = 1s
  }

  func test_classifier_retries_transient_urlErrors() {
    let codes: [URLError.Code] = [
      .timedOut, .networkConnectionLost, .notConnectedToInternet,
      .dnsLookupFailed, .cannotConnectToHost, .cannotFindHost,
    ]
    for code in codes {
      let d = classify(
        response: nil, error: URLError(code), attempt: 0, policy: policy,
        retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
      )
      XCTAssertEqual(d, .retry(after: .milliseconds(200)), "code=\(code)")
    }
  }

  func test_classifier_giveUp_on_non_transient_urlErrors() {
    let codes: [URLError.Code] = [
      .cancelled, .userCancelledAuthentication, .secureConnectionFailed,
      .clientCertificateRejected, .badServerResponse,
    ]
    for code in codes {
      let d = classify(
        response: nil, error: URLError(code), attempt: 0, policy: policy,
        retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
      )
      XCTAssertEqual(d, .giveUp, "code=\(code)")
    }
  }

  func test_classifier_giveUp_on_4xx() {
    for status in [400, 401, 403, 404, 409, 410, 422] {
      let d = classify(
        response: makeResp(status), error: nil, attempt: 0, policy: policy,
        retryAfterHint: nil, nextDelayJitterMultiplier: 1.0
      )
      XCTAssertEqual(d, .giveUp, "status=\(status)")
    }
  }

  func test_classifier_jitter_applies_to_schedule_not_to_hint() {
    // Schedule[0] = 200ms, multiplier = 1.5 → 300ms.
    let schedDecision = classify(
      response: makeResp(502), error: nil, attempt: 0, policy: policy,
      retryAfterHint: nil, nextDelayJitterMultiplier: 1.5
    )
    XCTAssertEqual(schedDecision, .retry(after: .milliseconds(300)))

    // Hint = 2s, multiplier ignored (verbatim).
    let hintDecision = classify(
      response: makeResp(429), error: nil, attempt: 0, policy: policy,
      retryAfterHint: .seconds(2), nextDelayJitterMultiplier: 1.5
    )
    XCTAssertEqual(hintDecision, .retry(after: .seconds(2)))
  }

  // MARK: - Integration via MockURLProtocol

  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon"
  private let workspaceID = "11111111-1111-1111-1111-111111111111"

  override func tearDown() async throws { MockURLProtocol.handler = nil }

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeJWT(pubkey: String) -> String {
    let header = #"{"alg":"HS256","typ":"JWT"}"#
    let payload =
      #"{"pubkey":"\#(pubkey)","sub":"00000000-0000-0000-0000-000000000222"}"#
    func b64url(_ s: String) -> String {
      Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(header)).\(b64url(payload)).fake-sig"
  }

  /// Make a SupabaseClient with no-op sleep (skip wall-clock waits in retry loop).
  private func makeClient() -> SupabaseClient {
    SupabaseClient(
      baseURL: baseURL,
      anonKey: anonKey,
      urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
      },
      sleep: { _ in /* skip wall-clock */ }
    )
  }

  /// Plays auth bootstrap chain (signup → register_pubkey → token refresh
  /// with `pubkey` claim). Delegates other paths to `pathHandler`.
  private func bootstrap(
    adminPubkey: String,
    _ pathHandler: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
  ) {
    let jwt = makeJWT(pubkey: adminPubkey)
    MockURLProtocol.handler = { request, body in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let d = """
          {"access_token":"tok-1","refresh_token":"ref-1","user":{"id":"00000000-0000-0000-0000-000000000222"},"expires_at":9999999999}
          """.data(using: .utf8)!
        return (r, d)
      case "/functions/v1/register_pubkey":
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (r, #"{"ok":true}"#.data(using: .utf8)!)
      case "/auth/v1/token":
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let d = """
          {"access_token":"\(jwt)","refresh_token":"ref-2","user":{"id":"00000000-0000-0000-0000-000000000222"},"expires_at":9999999999}
          """.data(using: .utf8)!
        return (r, d)
      default:
        return pathHandler(request, body)
      }
    }
  }

  /// Task 2 — proves POST scope: 502 on create_join_request triggers a single
  /// attempt, NOT 4 retries. Confirms `retryable: false` pass-through path.
  func test_postNotRetriedOn502_throwsServerError_singleCall() async throws {
    let client = makeClient()
    let callBox = RetryCallCounter()
    bootstrap(adminPubkey: String(repeating: "a", count: 64)) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/functions/v1/create_join_request" {
        callBox.bump()
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
        return (r, Data())
      }
      XCTFail("unexpected path \(path)")
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }

    do {
      _ = try await client.invokeCreateJoinRequest(
        workspaceID: workspaceID,
        code: "TEST-CODE",
        displayName: "tester"
      )
      XCTFail("expected throw")
    } catch SupabaseError.serverError {
      // expected
    }
    XCTAssertEqual(callBox.value, 1, "POST must not retry — got \(callBox.value) attempts")
  }
}

/// Thread-safe call counter for handler closure (MockURLProtocol handler is
/// @Sendable; NSLock-backed reference type avoids data-race warnings).
private final class RetryCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _value = 0
  var value: Int { lock.withLock { _value } }
  func bump() { lock.withLock { _value += 1 } }
}
