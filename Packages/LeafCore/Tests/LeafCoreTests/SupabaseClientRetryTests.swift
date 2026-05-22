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

  /// Task 3 — GET retries on transient 502, succeeds on 3rd attempt.
  func test_getRetriesOnTransient502_succeedsOnThirdAttempt() async throws {
    let client = makeClient()
    let calls = RetryCallCounter()
    bootstrap(adminPubkey: String(repeating: "a", count: 64)) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/rest/v1/join_requests" {
        calls.bump()
        let status = (calls.value < 3) ? 502 : 200
        let r = HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body = (status == 200) ? "[]".data(using: .utf8)! : Data()
        return (r, body)
      }
      XCTFail("unexpected path \(path)")
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let rows = try await client.listPendingJoinRequests(workspaceID: workspaceID)
    XCTAssertEqual(rows.count, 0)
    XCTAssertEqual(calls.value, 3, "expected 3 attempts (2× 502 + 1× 200)")
  }

  /// Task 3 — GET exhausts retry budget on persistent 503, throws .serverError
  /// after the configured maxAttempts (default = 4).
  func test_getExhaustsOn503_throwsServerError_fourCalls() async throws {
    let client = makeClient()
    let calls = RetryCallCounter()
    bootstrap(adminPubkey: String(repeating: "a", count: 64)) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/rest/v1/join_requests" {
        calls.bump()
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        return (r, Data())
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    do {
      _ = try await client.listPendingJoinRequests(workspaceID: workspaceID)
      XCTFail("expected throw")
    } catch SupabaseError.serverError {
      // expected
    }
    XCTAssertEqual(calls.value, 4, "expected 4 attempts (maxAttempts = 4)")
  }

  /// Task 3 — 429 with Retry-After: N header sleeps for N seconds verbatim
  /// (no jitter applied) before the next attempt.
  func test_get429HonorsRetryAfterHeader_secondAttemptSucceeds() async throws {
    let captured = DurationCapture()
    let client = SupabaseClient(
      baseURL: baseURL,
      anonKey: anonKey,
      urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
      },
      sleep: { duration in captured.append(duration) }
    )
    let calls = RetryCallCounter()
    bootstrap(adminPubkey: String(repeating: "a", count: 64)) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/rest/v1/join_requests" {
        calls.bump()
        if calls.value == 1 {
          let r = HTTPURLResponse(
            url: request.url!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "2"])!
          return (r, Data())
        }
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (r, "[]".data(using: .utf8)!)
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    _ = try await client.listPendingJoinRequests(workspaceID: workspaceID)
    XCTAssertEqual(captured.values.first, .seconds(2), "Retry-After: 2 → 2s sleep, verbatim")
  }

  /// Task 3 — 429 with `{"retry_after_seconds": N}` body field (Slack/Edge
  /// convention used by triggerSlackPost) is honored when the HTTP header is
  /// absent. Same verbatim semantics — no jitter.
  func test_get429HonorsRetryAfterBodyField() async throws {
    let captured = DurationCapture()
    let client = SupabaseClient(
      baseURL: baseURL,
      anonKey: anonKey,
      urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
      },
      sleep: { duration in captured.append(duration) }
    )
    let calls = RetryCallCounter()
    bootstrap(adminPubkey: String(repeating: "a", count: 64)) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/rest/v1/join_requests" {
        calls.bump()
        if calls.value == 1 {
          let r = HTTPURLResponse(
            url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
          return (r, #"{"retry_after_seconds": 1}"#.data(using: .utf8)!)
        }
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (r, "[]".data(using: .utf8)!)
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    _ = try await client.listPendingJoinRequests(workspaceID: workspaceID)
    XCTAssertEqual(captured.values.first, .seconds(1))
  }

  /// Task 3 — 401 is M-III's job, not M-I. Single attempt → .unauthorized.
  func test_getNoRetryOn401_throwsUnauthorized_singleCall() async throws {
    let client = makeClient()
    let calls = RetryCallCounter()
    bootstrap(adminPubkey: String(repeating: "a", count: 64)) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/rest/v1/join_requests" {
        calls.bump()
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        return (r, Data())
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    do {
      _ = try await client.listPendingJoinRequests(workspaceID: workspaceID)
      XCTFail("expected throw")
    } catch SupabaseError.unauthorized {
      // expected
    }
    XCTAssertEqual(calls.value, 1, "401 must not retry — M-III's job")
  }

  /// Task 3 — 404 is permanent. Single attempt → .notFound.
  func test_getNoRetryOn404_throwsNotFound_singleCall() async throws {
    let client = makeClient()
    let calls = RetryCallCounter()
    bootstrap(adminPubkey: String(repeating: "a", count: 64)) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/rest/v1/join_requests" {
        calls.bump()
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (r, Data())
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    do {
      _ = try await client.listPendingJoinRequests(workspaceID: workspaceID)
      XCTFail("expected throw")
    } catch SupabaseError.notFound {
      // expected
    }
    XCTAssertEqual(calls.value, 1)
  }

  /// Task 3 — Outer Task cancellation while retry loop is sleeping propagates
  /// CancellationError, aborts the loop after the first HTTP attempt.
  func test_cancellation_propagatesDuringSleep() async throws {
    let client = SupabaseClient(
      baseURL: baseURL,
      anonKey: anonKey,
      urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
      },
      sleep: { _ in throw CancellationError() }
    )
    let calls = RetryCallCounter()
    bootstrap(adminPubkey: String(repeating: "a", count: 64)) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/rest/v1/join_requests" {
        calls.bump()
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
        return (r, Data())
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    do {
      _ = try await client.listPendingJoinRequests(workspaceID: workspaceID)
      XCTFail("expected CancellationError")
    } catch is CancellationError {
      // expected — sleep threw, retry loop propagates
    }
    XCTAssertEqual(calls.value, 1, "cancellation aborts retry — only the first HTTP attempt ran")
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

/// Thread-safe Duration accumulator for inspecting `sleep` closure
/// invocations from retry loop. Same NSLock-backed pattern.
private final class DurationCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var _values: [Duration] = []
  var values: [Duration] { lock.withLock { _values } }
  func append(_ d: Duration) { lock.withLock { _values.append(d) } }
}
