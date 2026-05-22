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

  /// M-III — Persistent 401 on refreshable callsite: first 401 triggers
  /// ensureFreshSession (force), second 401 with new JWT proves the
  /// problem isn't a stale token. Caller throws .unauthorized after 2 attempts.
  func test_persistent401OnRefreshable_throwsUnauthorized_twoCalls() async throws {
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
    XCTAssertEqual(
      calls.value, 2,
      "M-III refreshable: 1 attempt + 1 retry after forced refresh = 2 attempts")
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

  // MARK: - M-III tests — 401 auto-refresh + retry-once

  /// Stateful bootstrap variant. The `/auth/v1/token` endpoint rotates JWTs:
  /// first call returns `jwt1` (initial bootstrap); subsequent calls return
  /// `jwt2` (refresh path). Non-auth paths delegate to `pathHandler`.
  /// Lets tests verify the Authorization header was actually rotated after
  /// ensureFreshSession.
  private func bootstrapWithRotatingJWT(
    adminPubkey: String,
    jwt1: String,
    jwt2: String,
    _ pathHandler: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
  ) {
    let tokenCalls = RetryCallCounter()
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
        tokenCalls.bump()
        let jwt = (tokenCalls.value == 1) ? jwt1 : jwt2
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let d = """
          {"access_token":"\(jwt)","refresh_token":"ref-\(tokenCalls.value + 1)","user":{"id":"00000000-0000-0000-0000-000000000222"},"expires_at":9999999999}
          """.data(using: .utf8)!
        return (r, d)
      default:
        return pathHandler(request, body)
      }
    }
  }

  /// M-III happy path — 401 with old JWT → ensureFreshSession(force:true)
  /// → server returns new JWT → retry with new Authorization Bearer → 200.
  /// Verifies (a) 2 calls to list, (b) second call carries new JWT.
  func test_401WithRefreshable_callsEnsureFreshSession_andRetriesWithNewJWT() async throws {
    let client = makeClient()
    let pubkey = String(repeating: "a", count: 64)
    let jwt1 = makeJWT(pubkey: pubkey)
    let jwt2 = makeJWT(pubkey: String(repeating: "b", count: 64))  // distinct claim
    let calls = RetryCallCounter()
    let observedAuthHeaders = AuthHeaderCapture()
    bootstrapWithRotatingJWT(adminPubkey: pubkey, jwt1: jwt1, jwt2: jwt2) { request, _ in
      let path = request.url?.path ?? ""
      if path == "/rest/v1/join_requests" {
        calls.bump()
        observedAuthHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        if calls.value == 1 {
          let r = HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
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
    let rows = try await client.listPendingJoinRequests(workspaceID: workspaceID)
    XCTAssertEqual(rows.count, 0)
    XCTAssertEqual(calls.value, 2, "expected 1 attempt + 1 retry after refresh")
    let headers = observedAuthHeaders.values
    XCTAssertEqual(headers.count, 2)
    XCTAssertEqual(headers[0], "Bearer \(jwt1)", "first attempt uses initial bootstrap JWT")
    XCTAssertEqual(headers[1], "Bearer \(jwt2)", "second attempt uses refreshed JWT")
  }

  /// M-III — Refresh endpoint itself errors (5xx during /auth/v1/token).
  /// Underlying server error propagates; original 401 is NOT silently swallowed.
  func test_401Refresh_endpointFails_propagatesRefreshError() async throws {
    let client = makeClient()
    let pubkey = String(repeating: "a", count: 64)
    let initialJWT = makeJWT(pubkey: pubkey)
    let tokenCalls = RetryCallCounter()
    let listCalls = RetryCallCounter()
    MockURLProtocol.handler = { request, _ in
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
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"ok":true}"#.data(using: .utf8)!
        )
      case "/auth/v1/token":
        tokenCalls.bump()
        // First /auth/v1/token = bootstrap (success); second = refresh after
        // 401 (return 503 to simulate refresh-endpoint outage).
        if tokenCalls.value == 1 {
          let r = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
          let d = """
            {"access_token":"\(initialJWT)","refresh_token":"ref-2","user":{"id":"00000000-0000-0000-0000-000000000222"},"expires_at":9999999999}
            """.data(using: .utf8)!
          return (r, d)
        }
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        return (r, Data())
      case "/rest/v1/join_requests":
        listCalls.bump()
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        return (r, Data())
      default:
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
    do {
      _ = try await client.listPendingJoinRequests(workspaceID: workspaceID)
      XCTFail("expected throw")
    } catch SupabaseError.serverError {
      // expected — refresh /auth/v1/token returned 503
    } catch SupabaseError.unauthorized {
      XCTFail("got .unauthorized — refresh error should propagate, not be swallowed")
    }
    XCTAssertEqual(listCalls.value, 1, "only the initial 401 — refresh failed before retry")
  }

  /// M-III — Concurrent 401s share ONE refresh call (proves
  /// inflightFreshSessionTask coalescing under M-III's force=true path).
  func test_concurrent401_sharesOneRefreshCall() async throws {
    let client = makeClient()
    let pubkey = String(repeating: "a", count: 64)
    let jwt1 = makeJWT(pubkey: pubkey)
    let jwt2 = makeJWT(pubkey: String(repeating: "c", count: 64))
    let listCalls = RetryCallCounter()
    let tokenCalls = RetryCallCounter()
    MockURLProtocol.handler = { request, _ in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          {"access_token":"tok-1","refresh_token":"ref-1","user":{"id":"00000000-0000-0000-0000-000000000222"},"expires_at":9999999999}
          """.data(using: .utf8)!
        )
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"ok":true}"#.data(using: .utf8)!
        )
      case "/auth/v1/token":
        tokenCalls.bump()
        let jwt = (tokenCalls.value == 1) ? jwt1 : jwt2
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          {"access_token":"\(jwt)","refresh_token":"ref-\(tokenCalls.value + 1)","user":{"id":"00000000-0000-0000-0000-000000000222"},"expires_at":9999999999}
          """.data(using: .utf8)!
        )
      case "/rest/v1/join_requests":
        listCalls.bump()
        let status = (listCalls.value <= 3) ? 401 : 200
        let r = HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body = (status == 200) ? "[]".data(using: .utf8)! : Data()
        return (r, body)
      default:
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
    // Bootstrap once so tokenCalls=1 before parallel fan-out.
    _ = try await client.ensureAuthenticated()

    // Sendable-safe parallel fan-out via TaskGroup (avoids `async let` +
    // self-capture data-race warning under Swift 6 strict concurrency).
    let wid = workspaceID  // local Sendable copy
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<3 {
        group.addTask {
          _ = try await client.listPendingJoinRequests(workspaceID: wid)
        }
      }
      try await group.waitForAll()
    }

    // 3 fan-out calls × (401 + 200) = 6 list calls total.
    XCTAssertEqual(listCalls.value, 6, "expected 3 initial 401s + 3 retries")
    // Bootstrap (1) + ONE refresh (1) shared by 3 concurrent 401 paths = 2 total.
    XCTAssertEqual(tokenCalls.value, 2, "expected 1 bootstrap + 1 coalesced refresh")
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

/// Thread-safe Authorization-header capture for M-III tests. Same pattern.
private final class AuthHeaderCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var _values: [String] = []
  var values: [String] { lock.withLock { _values } }
  func append(_ s: String) { lock.withLock { _values.append(s) } }
}
