// Phase Track-5 S4 — SupabaseClient DM + APNs endpoints coverage.

import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientDirectMessagesTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"
  private let pubkey = String(repeating: "42", count: 32)
  private let userID = "00000000-0000-0000-0000-000000000fff"

  override func tearDown() async throws {
    MockURLProtocol.handler = nil
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

  /// Common bootstrap handler — handles signup + register + refresh sequence so
  /// the actor's `ensureAuthenticated` succeeds before specific DM methods test their own request.
  private func wrapWithBootstrap(
    _ dmHandler: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
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
        return dmHandler(request, body)
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

  // MARK: - sendDirectMessage

  func testSendDirectMessage_Success_ReturnsRow() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      XCTAssertEqual(request.url?.path, "/rest/v1/direct_messages")
      XCTAssertEqual(request.httpMethod, "POST")
      // PostgREST insertion headers.
      XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation")
      return (
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
        Data(
          """
          [{ "message_id": "11111111-1111-1111-1111-111111111111", "created_at": "2026-05-14T10:00:00Z" }]
          """.utf8)
      )
    }

    let client = makeClient()
    let result = try await client.sendDirectMessage(
      workspaceID: "ws-1",
      recipientPubkeyHex: String(repeating: "b", count: 64),
      kind: .handoff,
      encryptedPayload: Data([0xAB, 0xCD, 0xEF]),
      replyTo: nil
    )
    XCTAssertEqual(result.messageID, "11111111-1111-1111-1111-111111111111")
    XCTAssertEqual(result.createdAtISO, "2026-05-14T10:00:00Z")
  }

  func testSendDirectMessage_403RLSForbidden_Throws() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
        Data(#"{"message":"insufficient privilege"}"#.utf8)
      )
    }
    let client = makeClient()
    do {
      _ = try await client.sendDirectMessage(
        workspaceID: "ws-1",
        recipientPubkeyHex: String(repeating: "b", count: 64),
        kind: .ping,
        encryptedPayload: Data(),
        replyTo: nil
      )
      XCTFail("expected throw")
    } catch _ as SupabaseError {
      // pass
    }
  }

  // MARK: - fetchInboundMessages

  func testFetchInboundMessages_Success_DecodesRows() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      XCTAssertEqual(request.url?.path, "/rest/v1/direct_messages")
      XCTAssertEqual(request.httpMethod, "GET")
      let queryString = request.url?.query ?? ""
      XCTAssertTrue(queryString.contains("workspace_id=eq.ws-1"))
      XCTAssertTrue(queryString.contains("recipient_pubkey=eq."))
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(
          """
          [
            {
              "message_id": "22222222-2222-2222-2222-222222222222",
              "workspace_id": "ws-1",
              "sender_pubkey": "shex",
              "recipient_pubkey": "rhex",
              "kind": "ping",
              "encrypted_payload": "\\\\xabcd",
              "cross_post": null,
              "created_at": "2026-05-14T10:00:00Z",
              "read_at": null,
              "done_at": null,
              "done_by_pubkey": null,
              "reply_to": null
            }
          ]
          """.utf8)
      )
    }
    let client = makeClient()
    let rows = try await client.fetchInboundMessages(
      workspaceID: "ws-1",
      recipientPubkeyHex: "rhex",
      sinceCreatedAtISO: nil,
      limit: 100
    )
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].messageID, "22222222-2222-2222-2222-222222222222")
    XCTAssertEqual(rows[0].encryptedPayload, Data([0xAB, 0xCD]))
  }

  func testFetchInboundMessages_SinceISOAppended() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      let queryString = request.url?.query ?? ""
      XCTAssertTrue(queryString.contains("created_at=gt.2026-05-14"))
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data("[]".utf8)
      )
    }
    let client = makeClient()
    _ = try await client.fetchInboundMessages(
      workspaceID: "ws-1",
      recipientPubkeyHex: "rhex",
      sinceCreatedAtISO: "2026-05-14T10:00:00Z",
      limit: 100
    )
  }

  func testFetchInboundMessages_EmptyArray() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data("[]".utf8)
      )
    }
    let client = makeClient()
    let rows = try await client.fetchInboundMessages(
      workspaceID: "ws-1", recipientPubkeyHex: "rhex",
      sinceCreatedAtISO: nil, limit: 100
    )
    XCTAssertTrue(rows.isEmpty)
  }

  // MARK: - fetchOutboundMessages

  func testFetchOutboundMessages_FilterBySender() async throws {
    let expectedPubkey = pubkey
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      let queryString = request.url?.query ?? ""
      XCTAssertTrue(queryString.contains("sender_pubkey=eq.\(expectedPubkey)"))
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data("[]".utf8)
      )
    }
    let client = makeClient()
    _ = try await client.fetchOutboundMessages(
      workspaceID: "ws-1", senderPubkeyHex: pubkey,
      sinceCreatedAtISO: nil, limit: 100
    )
  }

  // MARK: - markRead / markDone

  func testMarkRead_Success() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      XCTAssertEqual(request.httpMethod, "PATCH")
      XCTAssertTrue(request.url?.absoluteString.contains("message_id=eq.msg-1") == true)
      return (
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    try await client.markRead(messageID: "msg-1", readAtISO: "2026-05-14T10:00:00Z")
  }

  func testMarkDone_Success() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, body in
      XCTAssertEqual(request.httpMethod, "PATCH")
      let bodyStr = String(data: body, encoding: .utf8) ?? ""
      XCTAssertTrue(bodyStr.contains("done_at"))
      XCTAssertTrue(bodyStr.contains("done_by_pubkey"))
      return (
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    try await client.markDone(
      messageID: "msg-1",
      doneAtISO: "2026-05-14T10:00:00Z",
      doneByPubkeyHex: pubkey
    )
  }

  // MARK: - registerAPNsToken

  func testRegisterAPNsToken_UpsertSuccess() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      XCTAssertEqual(request.url?.path, "/rest/v1/apns_tokens")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Prefer"), "resolution=merge-duplicates, return=minimal")
      return (
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    try await client.registerAPNsToken(
      deviceID: "device-1",
      apnsToken: "abc123",
      environment: "development"
    )
  }

  // MARK: - triggerAPNsPush

  func testTriggerAPNsPush_Success_ReturnsResult() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      XCTAssertEqual(request.url?.path, "/functions/v1/apns_push")
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(#"{"ok":true,"devices_pushed":2,"errors":[]}"#.utf8)
      )
    }
    let client = makeClient()
    let result = try await client.triggerAPNsPush(
      workspaceID: "ws-1",
      recipientPubkeyHex: String(repeating: "b", count: 64),
      messageID: "msg-1",
      titleText: "Sasha sent a handoff",
      kind: "handoff"
    )
    XCTAssertEqual(result.devicesPushed, 2)
    XCTAssertTrue(result.errors.isEmpty)
    XCTAssertFalse(result.skippedByPrefs)
  }

  func testTriggerAPNsPush_PartialFailure_CarriesErrors() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(
          """
          {
            "ok": true,
            "devices_pushed": 1,
            "errors": [
              { "device_id": "old-device", "status": 410, "reason": "Unregistered" }
            ]
          }
          """.utf8)
      )
    }
    let client = makeClient()
    let result = try await client.triggerAPNsPush(
      workspaceID: "ws-1",
      recipientPubkeyHex: String(repeating: "b", count: 64),
      messageID: "msg-1",
      titleText: "Sasha sent a handoff",
      kind: "handoff"
    )
    XCTAssertEqual(result.devicesPushed, 1)
    XCTAssertEqual(result.errors.count, 1)
    XCTAssertEqual(result.errors[0].status, 410)
    XCTAssertEqual(result.errors[0].reason, "Unregistered")
  }

  func testTriggerAPNsPush_500_Throws() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    do {
      _ = try await client.triggerAPNsPush(
        workspaceID: "ws-1",
        recipientPubkeyHex: String(repeating: "b", count: 64),
        messageID: "msg-1",
        titleText: "x",
        kind: "handoff"
      )
      XCTFail("expected throw")
    } catch _ as SupabaseError {
      // pass
    }
  }

  // MARK: - T5 additions

  /// Track 5 / S8 / T5 — verify body includes `kind` field forwarded to the
  /// Edge Function (consumed for category, thread-id format, prefs lookup).
  func testTriggerAPNsPush_Body_IncludesKind() async throws {
    // Sendable capture box — handler closure is @Sendable.
    actor BodyCapture {
      var data: Data?
      func set(_ d: Data) { data = d }
    }
    let capture = BodyCapture()
    MockURLProtocol.handler = wrapWithBootstrap { request, requestBody in
      // MockURLProtocol's second handler arg already provides the body
      // (drains request.httpBodyStream into Data); reuse it directly
      // instead of re-reading.
      Task { await capture.set(requestBody) }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(#"{"ok":true,"devices_pushed":1,"errors":[]}"#.utf8)
      )
    }
    let client = makeClient()
    _ = try await client.triggerAPNsPush(
      workspaceID: "ws-1",
      recipientPubkeyHex: String(repeating: "b", count: 64),
      messageID: "msg-1",
      titleText: "Sasha assigned a task",
      kind: "task"
    )
    // Drain the actor-side Task that captured the body.
    await Task.yield()
    let body = await capture.data
    guard let body else {
      XCTFail("body not captured")
      return
    }
    let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    XCTAssertEqual(
      parsed?["kind"] as? String, "task",
      "kind field is required for Edge Function category/prefs path")
  }

  /// Track 5 / S8 / T5 — server returns `skipped_by_prefs: true` when the
  /// recipient has disabled this kind in `notification_prefs`. SDK reads
  /// this flag (no error path — successful no-op).
  func testTriggerAPNsPush_SkippedByPrefs_SurfacedInResult() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(#"{"ok":true,"devices_pushed":0,"skipped_by_prefs":true}"#.utf8)
      )
    }
    let client = makeClient()
    let result = try await client.triggerAPNsPush(
      workspaceID: "ws-1",
      recipientPubkeyHex: String(repeating: "b", count: 64),
      messageID: "msg-1",
      titleText: "x",
      kind: "ping"
    )
    XCTAssertEqual(result.devicesPushed, 0)
    XCTAssertTrue(
      result.errors.isEmpty,
      "prefs-skip response omits errors array")
    XCTAssertTrue(result.skippedByPrefs)
  }
}
