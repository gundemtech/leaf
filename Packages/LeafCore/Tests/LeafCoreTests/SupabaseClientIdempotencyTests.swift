//
//  SupabaseClientIdempotencyTests.swift
//  LeafCoreTests
//
//  Phase M-II (spec §2.4) — 15 scenarios verifying idempotent:Bool flag on
//  performHTTP. When true, one UUID v4 (lowercase) is generated before the
//  retry loop and injected as Idempotency-Key; the key survives every M-I
//  retry AND the M-III Authorization swap.
//

import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientIdempotencyTests: XCTestCase {

  // MARK: - Shared fixtures

  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon"
  private let workspaceID = "11111111-1111-1111-1111-111111111111"

  /// UUID v4 lowercase regex: 8-4-4-4-12 hex groups, version nibble = 4,
  /// variant nibble ∈ {8,9,a,b}.
  private let uuidV4Regex = try! NSRegularExpression(
    pattern:
      "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    options: []
  )

  override func tearDown() async throws { MockURLProtocol.handler = nil }

  // MARK: - Helpers

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeClient(
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
  ) -> SupabaseClient {
    SupabaseClient(
      baseURL: baseURL,
      anonKey: anonKey,
      urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(
          rawRepresentation: Data(repeating: 0xAA, count: 32))
      },
      sleep: sleep
    )
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

  private func makeRequest() -> URLRequest {
    URLRequest(url: baseURL.appendingPathComponent("functions/v1/test_fn"))
  }

  private func ok200(_ request: URLRequest, body: Data = Data()) -> (HTTPURLResponse, Data) {
    let r = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (r, body)
  }

  private func resp(_ status: Int, _ request: URLRequest, body: Data = Data()) -> (
    HTTPURLResponse, Data
  ) {
    let r = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (r, body)
  }

  private func isUUIDv4(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return uuidV4Regex.firstMatch(in: s, options: [], range: range) != nil
  }

  /// Bootstrap auth chain (signup → register_pubkey → token refresh with pubkey claim),
  /// delegating other paths to `pathHandler`.
  private func bootstrap(
    client: SupabaseClient,
    adminPubkey: String,
    pathHandler: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
  ) {
    let jwt = makeJWT(pubkey: adminPubkey)
    MockURLProtocol.handler = { [jwt] request, body in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          {"access_token":"tok-1","refresh_token":"ref-1",
           "user":{"id":"00000000-0000-0000-0000-000000000222"},
           "expires_at":9999999999}
          """.data(using: .utf8)!
        )
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"ok":true}"#.data(using: .utf8)!
        )
      case "/auth/v1/token":
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          {"access_token":"\(jwt)","refresh_token":"ref-2",
           "user":{"id":"00000000-0000-0000-0000-000000000222"},
           "expires_at":9999999999}
          """.data(using: .utf8)!
        )
      default:
        return pathHandler(request, body)
      }
    }
  }

  // MARK: - #1 idempotent:true injects UUID v4 lowercase header

  func test_01_idempotentTrue_injectsUUIDv4Header() async throws {
    let client = makeClient()
    let captured = IdempotencyKeyCapture()
    MockURLProtocol.handler = { request, _ in
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      return self.ok200(request)
    }
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: false, idempotent: true, label: "t1")
    let key = try XCTUnwrap(captured.keys.first.flatMap { $0 })
    XCTAssertTrue(isUUIDv4(key), "Expected UUID v4 lowercase, got: \(key)")
  }

  // MARK: - #2 idempotent:false injects NO Idempotency-Key header

  func test_02_idempotentFalse_noHeader() async throws {
    let client = makeClient()
    let captured = IdempotencyKeyCapture()
    MockURLProtocol.handler = { request, _ in
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      return self.ok200(request)
    }
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: false, idempotent: false, label: "t2")
    // allSatisfy handles [nil] correctly: every element is nil → no key injected.
    XCTAssertTrue(
      captured.keys.allSatisfy { $0 == nil },
      "idempotent:false must not inject Idempotency-Key")
  }

  // MARK: - #3 retry on 502 → 2nd attempt carries the SAME key

  func test_03_retryOn502_sameKeyOnBothAttempts() async throws {
    let client = makeClient()
    let captured = IdempotencyKeyCapture()
    let counter = IdemAtomicCounter()
    MockURLProtocol.handler = { request, _ in
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      counter.increment()
      return counter.value == 1
        ? self.resp(502, request) : self.ok200(request)
    }
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: true, idempotent: true, label: "t3")
    XCTAssertEqual(captured.keys.count, 2, "expected 2 attempts")
    let k0 = try XCTUnwrap(captured.keys[0])
    let k1 = try XCTUnwrap(captured.keys[1])
    XCTAssertEqual(k0, k1, "same key must ride both attempts")
    XCTAssertTrue(isUUIDv4(k0))
  }

  // MARK: - #4 retry on 503 (2×) → all 3 attempts share ONE key

  func test_04_retryOn503_threeAttemptsSameKey() async throws {
    let client = makeClient()
    let captured = IdempotencyKeyCapture()
    let counter = IdemAtomicCounter()
    MockURLProtocol.handler = { request, _ in
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      counter.increment()
      return counter.value < 3
        ? self.resp(503, request) : self.ok200(request)
    }
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: true, idempotent: true, label: "t4")
    XCTAssertEqual(captured.keys.count, 3, "expected 3 attempts")
    let uniqueKeys = Set(captured.keys.compactMap { $0 })
    XCTAssertEqual(uniqueKeys.count, 1, "all 3 attempts must share one key")
  }

  // MARK: - #5 retry on 429 with Retry-After → key preserved

  func test_05_retryOn429_keyPreservedAcrossRetryAfter() async throws {
    let client = makeClient()
    let captured = IdempotencyKeyCapture()
    let counter = IdemAtomicCounter()
    MockURLProtocol.handler = { request, _ in
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      counter.increment()
      if counter.value == 1 {
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 429, httpVersion: nil,
          headerFields: ["Retry-After": "0"])!
        return (r, Data())
      }
      return self.ok200(request)
    }
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: true, idempotent: true, label: "t5")
    XCTAssertEqual(captured.keys.count, 2)
    let k0 = try XCTUnwrap(captured.keys[0])
    let k1 = try XCTUnwrap(captured.keys[1])
    XCTAssertEqual(k0, k1, "key must survive 429 + Retry-After retry")
  }

  // MARK: - #6 networkConnectionLost retry → key preserved

  func test_06_networkConnectionLost_keyPreserved() async throws {
    let client = makeClient()
    let captured = IdempotencyKeyCapture()
    let counter = IdemAtomicCounter()
    MockURLProtocol.handler = { request, _ in
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      counter.increment()
      if counter.value == 1 {
        throw URLError(.networkConnectionLost)
      }
      return self.ok200(request)
    }
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: true, idempotent: true, label: "t6")
    XCTAssertEqual(captured.keys.count, 2)
    let k0 = try XCTUnwrap(captured.keys[0])
    let k1 = try XCTUnwrap(captured.keys[1])
    XCTAssertEqual(k0, k1, "key must survive networkConnectionLost retry")
  }

  // MARK: - #7 200 replay returns server body (decode request_id)

  func test_07_200replay_returnsServerBody() async throws {
    let client = makeClient()
    let replayBody = #"{"request_id":"abc-123","ok":true}"#.data(using: .utf8)!
    MockURLProtocol.handler = { request, _ in
      let r = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (r, replayBody)
    }
    let (data, http) = try await client._performHTTPForTesting(
      makeRequest(), retryable: false, idempotent: true, label: "t7")
    XCTAssertEqual(http.statusCode, 200)
    let json = try XCTUnwrap(
      try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["request_id"] as? String, "abc-123")
  }

  // MARK: - #8 422 surfaces as .unexpected(status:422)

  /// SupabaseError.fromStatus(422) returns .unexpected(status:422) — verified
  /// from SupabaseError.swift: the default case covers all unhandled statuses.
  func test_08_422_surfacesAsUnexpected() async throws {
    let client = makeClient()
    MockURLProtocol.handler = { request, _ in
      return self.resp(422, request, body: Data())
    }
    do {
      let (data, http) = try await client._performHTTPForTesting(
        makeRequest(), retryable: false, idempotent: true, label: "t8")
      // performHTTP returns the (data, http) directly — caller maps status.
      let err = SupabaseError.fromStatus(http.statusCode, body: data)
      XCTAssertEqual(err, .unexpected(status: 422))
    } catch {
      XCTFail("unexpected throw: \(error)")
    }
  }

  // MARK: - #9 400 surfaces as .badRequest

  /// SupabaseError.fromStatus(400) returns .badRequest — verified from
  /// SupabaseError.swift case 400.
  func test_09_400_surfacesAsBadRequest() async throws {
    let client = makeClient()
    MockURLProtocol.handler = { request, _ in
      return self.resp(400, request, body: Data())
    }
    do {
      let (data, http) = try await client._performHTTPForTesting(
        makeRequest(), retryable: false, idempotent: true, label: "t9")
      let err = SupabaseError.fromStatus(http.statusCode, body: data)
      XCTAssertEqual(err, .badRequest)
    } catch {
      XCTFail("unexpected throw: \(error)")
    }
  }

  // MARK: - #10 after 401 refresh, key is preserved across refresh+retry

  func test_10_refreshableAndIdempotent_keyPreservedAcrossRefresh() async throws {
    let client = makeClient()
    let pubkey = String(repeating: "a", count: 64)
    let jwt2 = makeJWT(pubkey: String(repeating: "b", count: 64))
    let captured = IdempotencyKeyCapture()
    let counter = IdemAtomicCounter()
    let tokenCounter = IdemAtomicCounter()

    MockURLProtocol.handler = { [jwt2] request, body in
      let path = request.url?.path ?? ""
      let query = request.url?.query ?? ""
      switch path {
      case "/auth/v1/token" where query.contains("grant_type=password"):
        // Phase 1 — native login installs the initial authenticated session
        // (replaces the removed anonymous-signup bootstrap).
        let jwt1 = self.makeJWT(pubkey: pubkey)
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (
          r,
          """
          {"access_token":"\(jwt1)","refresh_token":"ref-1",
           "user":{"id":"00000000-0000-0000-0000-000000000222"},
           "expires_at":9999999999}
          """.data(using: .utf8)!
        )
      case "/auth/v1/token":
        // grant_type=refresh_token — the 401-recovery refresh.
        tokenCounter.increment()
        let jwt = tokenCounter.value == 1 ? self.makeJWT(pubkey: pubkey) : jwt2
        let r = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (
          r,
          """
          {"access_token":"\(jwt)","refresh_token":"ref-\(tokenCounter.value + 1)",
           "user":{"id":"00000000-0000-0000-0000-000000000222"},
           "expires_at":9999999999}
          """.data(using: .utf8)!
        )
      case "/functions/v1/test_fn":
        captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
        counter.increment()
        if counter.value == 1 {
          // First attempt → 401 to trigger refresh
          return self.resp(401, request)
        }
        return self.ok200(request)
      default:
        return self.resp(500, request)
      }
    }

    // Phase 1 — establish an authenticated session via native login.
    _ = try await client.signInWithPassword(email: "a@b.co", password: "pw", captchaToken: "c")

    // Now make a refreshable + idempotent call that triggers a 401.
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: false, refreshable: true, idempotent: true, label: "t10")

    XCTAssertEqual(counter.value, 2, "expected 1 attempt (401) + 1 retry after refresh")
    XCTAssertEqual(captured.keys.count, 2)
    let k0 = try XCTUnwrap(captured.keys[0])
    let k1 = try XCTUnwrap(captured.keys[1])
    XCTAssertEqual(k0, k1, "Idempotency-Key must survive 401 refresh + retry")
    XCTAssertTrue(isUUIDv4(k0))
  }

  // MARK: - #11 two distinct performHTTP calls generate DISTINCT keys

  func test_11_twoDistinctCalls_distinctKeys() async throws {
    let client = makeClient()
    let captured = IdempotencyKeyCapture()
    MockURLProtocol.handler = { request, _ in
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      return self.ok200(request)
    }
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: false, idempotent: true, label: "call-a")
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: false, idempotent: true, label: "call-b")
    XCTAssertEqual(captured.keys.count, 2)
    let k0 = try XCTUnwrap(captured.keys[0])
    let k1 = try XCTUnwrap(captured.keys[1])
    XCTAssertNotEqual(k0, k1, "distinct logical calls must get distinct keys")
  }

  // MARK: - #12 UPSERT path (retryable:true, idempotent:false) carries NO key

  func test_12_upsert_noIdempotencyKey() async throws {
    let client = makeClient()
    let captured = IdempotencyKeyCapture()
    MockURLProtocol.handler = { request, _ in
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      return self.ok200(request)
    }
    _ = try await client._performHTTPForTesting(
      makeRequest(), retryable: true, idempotent: false, label: "upsert")
    XCTAssertTrue(
      captured.keys.allSatisfy { $0 == nil },
      "retryable:true idempotent:false must carry NO Idempotency-Key")
  }

  // MARK: - #13 removed — anonymous signup path deleted in Phase 1 (account-login).
  // The "Auth POST carries NO Idempotency-Key" contract stays covered by
  // #14 (performTokenRefresh) below.

  // MARK: - #14 performTokenRefresh (Auth POST) carries NO key

  func test_14_tokenRefresh_noKey() async throws {
    let client = makeClient()
    let pubkey = String(repeating: "a", count: 64)
    let captured = IdempotencyKeyCapture()
    let paths = PathCapture()

    MockURLProtocol.handler = { request, _ in
      let path = request.url?.path ?? ""
      let query = request.url?.query ?? ""
      paths.append(path)
      captured.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
      switch path {
      case "/auth/v1/token" where query.contains("grant_type=password"):
        // Phase 1 — native login (replaces removed anonymous signup).
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          {"access_token":"tok-1","refresh_token":"ref-1",
           "user":{"id":"00000000-0000-0000-0000-000000000222"},
           "expires_at":9999999999}
          """.data(using: .utf8)!
        )
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"ok":true}"#.data(using: .utf8)!
        )
      case "/auth/v1/token":
        // grant_type=refresh_token — post-register refresh.
        let jwt = self.makeJWT(pubkey: pubkey)
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          {"access_token":"\(jwt)","refresh_token":"ref-2",
           "user":{"id":"00000000-0000-0000-0000-000000000222"},
           "expires_at":9999999999}
          """.data(using: .utf8)!
        )
      default:
        return self.resp(500, request)
      }
    }

    // Phase 1 — native login + post-login pubkey registration drives the auth
    // POSTs (password login + register_pubkey + token refresh).
    _ = try await client.signInWithPassword(email: "a@b.co", password: "pw", captchaToken: "c")
    _ = try await client.ensureAuthenticatedAndPubkeyRegistered()

    // Verify that none of the auth endpoints received an Idempotency-Key.
    let authPaths = ["/auth/v1/token", "/functions/v1/register_pubkey"]
    let allPaths = paths.all
    let allKeys = captured.keys

    for (path, key) in zip(allPaths, allKeys) where authPaths.contains(path) {
      XCTAssertNil(key, "Auth POST \(path) must NOT receive Idempotency-Key; got \(key ?? "nil")")
    }
  }

  // MARK: - #15 (deferred — B9 flip callsite)
  // triggerLinearCreate body-field test deferred to B9: depends on
  // idempotent:true being wired at the callsite (B9 scope). The legacy
  // `linear_issue_id` body field is an orthogonal concern (B9 spec §3).
}

// MARK: - Thread-safe capture helpers

private final class IdempotencyKeyCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var _keys: [String?] = []
  var keys: [String?] { lock.withLock { _keys } }
  func append(_ k: String?) { lock.withLock { _keys.append(k) } }
}

private final class IdemAtomicCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _value = 0
  var value: Int { lock.withLock { _value } }
  func increment() { lock.withLock { _value += 1 } }
}

private final class PathCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var _paths: [String] = []
  var all: [String] { lock.withLock { _paths } }
  func append(_ p: String) { lock.withLock { _paths.append(p) } }
}
