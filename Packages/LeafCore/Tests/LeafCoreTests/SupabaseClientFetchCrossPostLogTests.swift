// Track 5 / S7 C.7 — SupabaseClient.fetchCrossPostLog endpoint tests.
//
// Mirrors SupabaseClientCrossPostTests pattern: MockURLProtocol bootstrap
// wrapper so ensureAuthenticated() completes before the target call fires.

import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientFetchCrossPostLogTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"
  private let pubkey = String(repeating: "42", count: 32)
  private let userID = "00000000-0000-0000-0000-000000000fff"

  override func tearDown() async throws {
    MockURLProtocol.handler = nil
  }

  // MARK: - Helpers

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func fixedIdentity() -> @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey {
    let bytes = Data(repeating: 0x42, count: 32)
    return { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
  }

  private func makeJWT() -> String {
    let header = #"{"alg":"HS256","typ":"JWT"}"#
    let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
    func b64url(_ s: String) -> String {
      Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(header)).\(b64url(payload)).sig"
  }

  /// Bootstrap handler — handles signup + register + refresh so actor's
  /// ensureAuthenticated() succeeds before the call under test fires.
  private func wrapWithBootstrap(
    _ next: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
  ) -> (@Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)) {
    let jwt = makeJWT()
    let uid = userID
    return { request, body in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "boot-tok", "refresh_token": "boot-rt",
            "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"ok":true}"#.utf8)
        )
      case "/auth/v1/token":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "\(jwt)", "refresh_token": "ref",
            "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      default:
        return next(request, body)
      }
    }
  }

  // Phase 1 (account-login) — anonymous bootstrap removed; seed a persisted
  // refresh-token so ensureAuthenticated() takes the persisted-refresh path
  // (served by wrapWithBootstrap's /auth/v1/token branch) instead of the
  // deleted anon signup.
  private func makeClient() -> SupabaseClient {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = SupabaseSessionStore(at: dir)
    try? store.write(PersistedSession(refreshToken: "seed-rt", userID: userID, savedAtMs: 1))
    return SupabaseClient(
      baseURL: baseURL, anonKey: anonKey,
      urlSession: makeSession(),
      identity: fixedIdentity(),
      sessionStore: store
    )
  }

  // MARK: - Sample JSON

  private static func sampleRowsJSON(messageID: String = "msg-aaa") -> Data {
    """
    [
      {
        "message_id": "\(messageID)",
        "platform": "slack",
        "external_ref": "#leaf-architecture",
        "external_url": "https://slack.com/archives/C12345/p1716900000",
        "posted_at_ms": 1716900000000,
        "error_text": null
      },
      {
        "message_id": "\(messageID)",
        "platform": "linear",
        "external_ref": "LEA-42",
        "external_url": "https://linear.app/leaf/issue/LEA-42/title",
        "posted_at_ms": 1716900001000,
        "error_text": null
      }
    ]
    """.data(using: .utf8)!
  }

  // MARK: - Tests

  /// Empty messageIDs → returns [] immediately, no network call.
  func testFetchCrossPostLog_EmptyInput_ReturnsEmpty_NoNetwork() async throws {
    // No MockURLProtocol handler installed — any network call would crash.
    MockURLProtocol.handler = { _, _ in
      XCTFail("fetchCrossPostLog([]) must not fire a network request")
      return (
        HTTPURLResponse(
          url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    let rows = try await client.fetchCrossPostLog(messageIDs: [])
    XCTAssertEqual(rows.count, 0)
  }

  /// Single ID → URL path is /rest/v1/cross_post_log and query contains
  /// `message_id=in.(msg-aaa)` (PostgREST IN filter syntax).
  func testFetchCrossPostLog_SingleID_CorrectURL() async throws {
    let targetID = "msg-aaa"
    nonisolated(unsafe) var capturedURL: URL?
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      capturedURL = request.url
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Self.sampleRowsJSON(messageID: targetID)
      )
    }
    let client = makeClient()
    _ = try await client.fetchCrossPostLog(messageIDs: [targetID])

    let url: URL = try XCTUnwrap(capturedURL)
    XCTAssertEqual(url.path, "/rest/v1/cross_post_log")
    let query = url.query ?? ""
    XCTAssertTrue(query.contains("message_id"), "query should filter by message_id, got: \(query)")
    XCTAssertTrue(query.contains("in."), "query should use PostgREST in.() operator, got: \(query)")
    XCTAssertTrue(query.contains(targetID), "query should contain the message ID, got: \(query)")
  }

  /// Multiple IDs → all IDs appear in the CSV inside in.(...).
  func testFetchCrossPostLog_MultipleIDs_CSVFilter() async throws {
    let ids = ["msg-aaa", "msg-bbb", "msg-ccc"]
    nonisolated(unsafe) var capturedQuery: String?
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      if request.url?.path == "/rest/v1/cross_post_log" {
        capturedQuery = request.url?.query
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(#"[]"#.utf8)
      )
    }
    let client = makeClient()
    _ = try await client.fetchCrossPostLog(messageIDs: ids)

    let query: String = try XCTUnwrap(capturedQuery)
    for id in ids {
      XCTAssertTrue(query.contains(id), "query should contain '\(id)', got: \(query)")
    }
  }

  /// Successful 200 response with two rows is decoded correctly into [CrossPostLogRow].
  func testFetchCrossPostLog_DecodesRowsCorrectly() async throws {
    let targetID = "msg-decode"
    MockURLProtocol.handler = wrapWithBootstrap { _, _ in
      return (
        HTTPURLResponse(
          url: URL(string: "https://test.supabase.co/rest/v1/cross_post_log")!,
          statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Self.sampleRowsJSON(messageID: targetID)
      )
    }
    let client = makeClient()
    let rows = try await client.fetchCrossPostLog(messageIDs: [targetID])

    XCTAssertEqual(rows.count, 2)
    let slack: CrossPostLogRow = try XCTUnwrap(rows.first { $0.platform == "slack" })
    XCTAssertEqual(slack.messageID, targetID)
    XCTAssertEqual(slack.externalRef, "#leaf-architecture")
    XCTAssertEqual(slack.externalURL, URL(string: "https://slack.com/archives/C12345/p1716900000")!)
    XCTAssertEqual(slack.postedAtMs, 1_716_900_000_000)
    XCTAssertNil(slack.errorText)

    let linear: CrossPostLogRow = try XCTUnwrap(rows.first { $0.platform == "linear" })
    XCTAssertEqual(linear.messageID, targetID)
    XCTAssertEqual(linear.externalRef, "LEA-42")
    XCTAssertEqual(linear.postedAtMs, 1_716_900_001_000)
  }

  /// Network transport failure → throws SupabaseError.transport.
  func testFetchCrossPostLog_NetworkFailure_Throws() async throws {
    // wrapWithBootstrap accepts a non-throwing inner closure, so we set the
    // error path directly without bootstrap wrapping (the bootstrap calls succeed,
    // then the cross-post-log path throws the transport error).
    let jwt = makeJWT()
    let uid = userID
    MockURLProtocol.handler = { request, body in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "boot-tok", "refresh_token": "boot-rt",
            "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"ok":true}"#.utf8)
        )
      case "/auth/v1/token":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "\(jwt)", "refresh_token": "ref",
            "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      default:
        // Simulate transport failure for the actual fetch call.
        throw URLError(.notConnectedToInternet)
      }
    }
    let client = makeClient()
    do {
      _ = try await client.fetchCrossPostLog(messageIDs: ["msg-1"])
      XCTFail("expected throw")
    } catch SupabaseError.transport {
      // pass
    } catch {
      XCTFail("expected SupabaseError.transport, got \(error)")
    }
  }

  /// Row with http:// external_url → decoding throws (HTTPS-only invariant from B.7).
  func testFetchCrossPostLog_NonHTTPSURLInRow_ThrowsDuringDecode() async throws {
    let badJSON = """
      [{
        "message_id": "msg-bad",
        "platform": "slack",
        "external_ref": "#ch",
        "external_url": "http://insecure.example.com/path",
        "posted_at_ms": 0,
        "error_text": null
      }]
      """.data(using: .utf8)!
    let jwt = makeJWT()
    let uid = userID
    MockURLProtocol.handler = { request, _ in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "boot-tok", "refresh_token": "boot-rt",
            "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"ok":true}"#.utf8)
        )
      case "/auth/v1/token":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          """
          { "access_token": "\(jwt)", "refresh_token": "ref",
            "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
          """.data(using: .utf8)!
        )
      default:
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          badJSON
        )
      }
    }
    let client = makeClient()
    do {
      _ = try await client.fetchCrossPostLog(messageIDs: ["msg-bad"])
      XCTFail("expected throw on non-HTTPS URL in JSON row")
    } catch SupabaseError.decoding {
      // pass — fetchCrossPostLog maps DecodingError → SupabaseError.decoding
    } catch {
      XCTFail("expected SupabaseError.decoding, got \(error)")
    }
  }
}
