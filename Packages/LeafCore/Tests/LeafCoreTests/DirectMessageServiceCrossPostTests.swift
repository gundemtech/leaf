// Phase Track-5 S6 — DirectMessageService.send cross-post extension coverage.
//
// Mirrors the existing DirectMessageServiceTests pattern (URLProtocol mock +
// real SupabaseClient + in-memory SQLCipher DB seeded with workspace + self
// team member + active key + keystore). Adds two optional params to send
// (crossPostSlack / crossPostLinear) and asserts the parallel-async-let
// branches against the slack_post and linear_create_issue Edge Function paths.

import CryptoKit
import XCTest

@testable import LeafCore

final class DirectMessageServiceCrossPostTests: XCTestCase {
  private var tempDir: URL!
  private var db: LeafCore.Database!
  private let workspaceID = "11111111-1111-1111-1111-111111111111"
  private let teamKeyID = "22222222-2222-2222-2222-222222222222"
  private let selfMemberID = "33333333-3333-3333-3333-333333333333"
  private let selfPubkey = String(repeating: "a", count: 64)
  private let recipientPubkey = String(repeating: "b", count: 64)
  private let messageID = "44444444-4444-4444-4444-444444444444"
  private let createdAtISO = "2026-05-16T10:00:00.000Z"

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-dm-xpost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    db = try LeafCore.Database.openForWrite(
      at: tempDir.appendingPathComponent("events.sqlite"),
      config: .weakDefaults,
      encryption: .deterministicTest
    )
    try db.upsertWorkspace(
      Workspace(
        id: workspaceID, name: "Acme",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        createdByMemberID: selfMemberID
      ))
    try db.insertTeamMember(
      TeamMember(
        id: selfMemberID, workspaceID: workspaceID, role: .admin,
        pubkeyHex: selfPubkey, displayName: "Anton",
        addedAt: Date(timeIntervalSince1970: 1_700_000_000), removedAt: nil
      ))
    try db.insertTeamKey(
      TeamKey(
        id: teamKeyID, workspaceID: workspaceID,
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        deprecatedAt: nil, generatedByMemberID: selfMemberID
      ))
    let teamKeyBytes = Data(repeating: 0xCC, count: 32)
    let keystoreRoot = tempDir.appendingPathComponent("keystore")
    try FileManager.default.createDirectory(at: keystoreRoot, withIntermediateDirectories: true)
    try TeamKeystore.writeTeamKey(
      teamKeyBytes,
      workspaceID: workspaceID,
      keyID: teamKeyID,
      at: keystoreRoot)
  }

  override func tearDown() async throws {
    db = nil
    MockURLProtocol.handler = nil
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - Helpers

  private func makeURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeJWT(pubkey: String) -> String {
    let header = #"{"alg":"HS256","typ":"JWT"}"#
    let payload = #"{"pubkey":"\#(pubkey)"}"#
    func b64url(_ s: String) -> String {
      Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(header)).\(b64url(payload)).sig"
  }

  private func seedSlackIntegration(token: String = "xoxp-slack-token") throws {
    try db.upsertIntegration(
      IntegrationRecord(
        provider: .slack,
        workspaceID: "T-slack-team",
        workspaceName: "Slack WS",
        accessToken: token,
        refreshToken: nil,
        expiresAt: nil,
        scope: "chat:write",
        connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ))
  }

  private func seedLinearIntegration(token: String = "lin_api_token") throws {
    try db.upsertIntegration(
      IntegrationRecord(
        provider: .linear,
        workspaceID: "linear-workspace",
        workspaceName: "Linear WS",
        accessToken: token,
        refreshToken: nil,
        expiresAt: nil,
        scope: "read,write,issues:create",
        connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ))
  }

  /// Records each /functions/v1/slack_post + /functions/v1/linear_create_issue
  /// request body for later assertion.
  private final class CallSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _slackCalls: [[String: Any]] = []
    private var _linearCalls: [[String: Any]] = []

    func recordSlack(_ body: [String: Any]) {
      lock.lock()
      defer { lock.unlock() }
      _slackCalls.append(body)
    }
    func recordLinear(_ body: [String: Any]) {
      lock.lock()
      defer { lock.unlock() }
      _linearCalls.append(body)
    }
    var slackCalls: [[String: Any]] {
      lock.lock()
      defer { lock.unlock() }
      return _slackCalls
    }
    var linearCalls: [[String: Any]] {
      lock.lock()
      defer { lock.unlock() }
      return _linearCalls
    }
  }

  /// HTTP handler producing successful bootstrap + DM POST + APNs trigger +
  /// configurable Slack/Linear cross-post responses. Sink records bodies.
  private func makeHandler(
    sink: CallSink,
    slackResponse: (status: Int, body: Data) = (
      200,
      Data(
        #"{"ok":true,"ts":"1700000000.000100","channel_id":"C12345","error":null,"retry_after_seconds":null}"#
          .utf8)
    ),
    linearResponse: (status: Int, body: Data) = (
      200,
      Data(
        #"{"ok":true,"issue_id":"issue-uuid-1","identifier":"LEA-42","url":"https://linear.app/leaf/issue/LEA-42","error":null}"#
          .utf8)
    )
  ) -> @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data) {
    let jwt = makeJWT(pubkey: selfPubkey)
    let messageID = self.messageID
    let createdAtISO = self.createdAtISO
    return { request, body in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(
            """
            { "access_token": "t", "refresh_token": "r",
              "user": { "id": "00000000-0000-0000-0000-000000000000" },
              "expires_at": 9999999999 }
            """.utf8)
        )
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"ok":true}"#.utf8)
        )
      case "/auth/v1/token":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(
            """
            { "access_token": "\(jwt)", "refresh_token": "r2",
              "user": { "id": "00000000-0000-0000-0000-000000000000" },
              "expires_at": 9999999999 }
            """.utf8)
        )
      case "/functions/v1/send_direct_message" where request.httpMethod == "POST":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
          Data(
            """
            { "message_id": "\(messageID)", "workspace_id": "11111111-1111-1111-1111-111111111111", "created_at": "\(createdAtISO)" }
            """.utf8)
        )
      case "/functions/v1/apns_push":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(#"{"ok":true,"devices_pushed":1,"errors":[]}"#.utf8)
        )
      case "/functions/v1/slack_post":
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
          sink.recordSlack(obj)
        }
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: slackResponse.status, httpVersion: nil, headerFields: nil
          )!,
          slackResponse.body
        )
      case "/functions/v1/linear_create_issue":
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
          sink.recordLinear(obj)
        }
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: linearResponse.status, httpVersion: nil,
            headerFields: nil)!,
          linearResponse.body
        )
      default:
        return (
          HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
  }

  private func makeService(supabase: SupabaseClient) -> DirectMessageService {
    let mid = messageID
    return DirectMessageService(
      database: db,
      supabase: supabase,
      codec: TestCrossPostCodec(),
      keystoreRoot: tempDir.appendingPathComponent("keystore"),
      generateMessageID: { mid }
    )
  }

  private func makeSupabase() -> SupabaseClient {
    SupabaseClient(
      baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
      urlSession: makeURLSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32))
      }
    )
  }

  // MARK: - Tests

  /// Test 1 — send without cross-post params → existing flow + statuses
  /// fields all nil.
  func testSend_NoCrossPostParams_StatusesAllNil() async throws {
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(sink: sink)
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .ping,
      body: "hi",
      notify: true
    )

    XCTAssertNil(result.crossPostStatuses.slack)
    XCTAssertNil(result.crossPostStatuses.linear)
    XCTAssertTrue(sink.slackCalls.isEmpty)
    XCTAssertTrue(sink.linearCalls.isEmpty)
  }

  /// Test 2 — Slack only → Linear leg NEVER invoked.
  func testSend_SlackOnly_DoesNotInvokeLinearTrigger() async throws {
    try seedSlackIntegration()
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(sink: sink)
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .handoff,
      body: "deploy ready for review",
      crossPostSlack: SlackCrossPostRequest(channelID: "C12345")
    )

    XCTAssertEqual(sink.slackCalls.count, 1)
    XCTAssertEqual(sink.linearCalls.count, 0)
    XCTAssertEqual(result.crossPostStatuses.slack?.ok, true)
    XCTAssertEqual(result.crossPostStatuses.slack?.ts, "1700000000.000100")
    XCTAssertNil(result.crossPostStatuses.linear)
  }

  /// Test 3 — Linear only → Slack leg NEVER invoked.
  func testSend_LinearOnly_DoesNotInvokeSlackTrigger() async throws {
    try seedLinearIntegration()
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(sink: sink)
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .task,
      body: "review M013 migration",
      crossPostLinear: LinearCrossPostRequest(teamID: "team-uuid")
    )

    XCTAssertEqual(sink.slackCalls.count, 0)
    XCTAssertEqual(sink.linearCalls.count, 1)
    XCTAssertEqual(result.crossPostStatuses.linear?.ok, true)
    XCTAssertEqual(result.crossPostStatuses.linear?.identifier, "LEA-42")
    XCTAssertNil(result.crossPostStatuses.slack)
  }

  /// Test 4 — both → both triggers called, both OK results captured.
  func testSend_BothParams_BothTriggersCalled() async throws {
    try seedSlackIntegration()
    try seedLinearIntegration()
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(sink: sink)
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .handoff,
      body: "cross-post both legs",
      crossPostSlack: SlackCrossPostRequest(channelID: "C12345"),
      crossPostLinear: LinearCrossPostRequest(teamID: "team-uuid")
    )

    XCTAssertEqual(sink.slackCalls.count, 1)
    XCTAssertEqual(sink.linearCalls.count, 1)
    XCTAssertEqual(result.crossPostStatuses.slack?.ok, true)
    XCTAssertEqual(result.crossPostStatuses.linear?.ok, true)
  }

  /// Test 5 — Slack requested, but NO IntegrationRecord in DB → "not_connected"
  /// returned without calling the Edge Function.
  func testSend_SlackParamButNoIntegration_NotConnectedResultNoTrigger() async throws {
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(sink: sink)
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .ping,
      body: "no slack token",
      crossPostSlack: SlackCrossPostRequest(channelID: "C12345")
    )

    XCTAssertEqual(sink.slackCalls.count, 0)
    XCTAssertEqual(result.crossPostStatuses.slack?.ok, false)
    XCTAssertEqual(result.crossPostStatuses.slack?.error, "not_connected")
    XCTAssertEqual(result.crossPostStatuses.slack?.channelID, "C12345")
  }

  /// Test 6 — same for Linear: no IntegrationRecord → "not_connected".
  func testSend_LinearParamButNoIntegration_NotConnectedResultNoTrigger() async throws {
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(sink: sink)
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .task,
      body: "no linear token",
      crossPostLinear: LinearCrossPostRequest(teamID: "team-uuid")
    )

    XCTAssertEqual(sink.linearCalls.count, 0)
    XCTAssertEqual(result.crossPostStatuses.linear?.ok, false)
    XCTAssertEqual(result.crossPostStatuses.linear?.error, "not_connected")
  }

  /// Test 7 — Slack triggerSlackPost throws (mocked 500) → captured as .error,
  /// NOT propagated. DM persists, push status still .sent.
  func testSend_SlackTriggerThrows_CapturedAsErrorNotPropagated() async throws {
    try seedSlackIntegration()
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(
      sink: sink,
      slackResponse: (500, Data(#"{"error":"boom"}"#.utf8))
    )
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .handoff,
      body: "transient slack outage",
      notify: true,
      crossPostSlack: SlackCrossPostRequest(channelID: "C12345")
    )

    XCTAssertEqual(result.crossPostStatuses.slack?.ok, false)
    XCTAssertNotNil(result.crossPostStatuses.slack?.error)
    XCTAssertEqual(result.crossPostStatuses.slack?.channelID, "C12345")
    // DM still succeeded — push triggered, mirror row written.
    XCTAssertEqual(result.pushDispatchStatus, .sent)
    let row = try db.readSQL { try MessagesMirrorStore.read(messageID: messageID, in: $0) }
    XCTAssertNotNil(row)
    XCTAssertEqual(row?.direction, .outbound)
  }

  /// Test 8 — both requested, Slack 500 / Linear 200. Independent statuses.
  func testSend_BothParams_IndependentSuccessAndFailure() async throws {
    try seedSlackIntegration()
    try seedLinearIntegration()
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(
      sink: sink,
      slackResponse: (500, Data(#"{"error":"server"}"#.utf8))
      // linearResponse default: 200 OK
    )
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .handoff,
      body: "half down half up",
      crossPostSlack: SlackCrossPostRequest(channelID: "C12345"),
      crossPostLinear: LinearCrossPostRequest(teamID: "team-uuid")
    )

    XCTAssertEqual(result.crossPostStatuses.slack?.ok, false)
    XCTAssertNotNil(result.crossPostStatuses.slack?.error)
    XCTAssertEqual(result.crossPostStatuses.linear?.ok, true)
    XCTAssertEqual(result.crossPostStatuses.linear?.identifier, "LEA-42")
  }

  /// Test 9 — A13: idempotency_key body field removed from triggerLinearCreate
  /// (server reads the Idempotency-Key header injected by performHTTP instead).
  /// The idempotencyKey parameter is still accepted for API compatibility but
  /// must NOT appear in the request body.
  func testSend_LinearIdempotencyKey_AbsentFromRequestBody() async throws {
    try seedLinearIntegration()
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(sink: sink)
    let svc = makeService(supabase: makeSupabase())

    let key = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    _ = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .task,
      body: "idempotent linear",
      crossPostLinear: LinearCrossPostRequest(teamID: "team-uuid", idempotencyKey: key)
    )

    XCTAssertEqual(sink.linearCalls.count, 1)
    let sent = sink.linearCalls[0]
    XCTAssertNil(
      sent["idempotency_key"],
      "Legacy idempotency_key must be absent from request body (A13 removal)")
  }

  /// Test 10 — messageID generated once for the send, passed verbatim into
  /// BOTH cross-post trigger request bodies (so cross_post_log.external_ref
  /// consistently joins to direct_messages.message_id).
  func testSend_MessageID_ConsistentAcrossBothTriggers() async throws {
    try seedSlackIntegration()
    try seedLinearIntegration()
    let sink = CallSink()
    MockURLProtocol.handler = makeHandler(sink: sink)
    let svc = makeService(supabase: makeSupabase())

    let result = try await svc.send(
      workspaceID: workspaceID,
      recipientPubkeyHex: recipientPubkey,
      recipientMemberID: nil,
      kind: .handoff,
      body: "consistent message id",
      crossPostSlack: SlackCrossPostRequest(channelID: "C12345"),
      crossPostLinear: LinearCrossPostRequest(teamID: "team-uuid")
    )

    XCTAssertEqual(result.messageID, messageID)
    let slackBody = sink.slackCalls.first
    let linearBody = sink.linearCalls.first
    XCTAssertEqual(slackBody?["message_id"] as? String, messageID)
    XCTAssertEqual(linearBody?["message_id"] as? String, messageID)
  }
}

// MARK: - Test fixture codec

private struct TestCrossPostCodec: DirectMessageBlobCodec {
  func encode(_ plaintext: DirectMessagePlaintext, keyID: Data, teamKey: Data) throws -> Data {
    var bytes = Data()
    bytes.append(0x03)
    bytes.append(keyID)
    bytes.append(Data(repeating: 0, count: 12))
    let json = try JSONEncoder().encode(plaintext)
    bytes.append(json)
    bytes.append(Data(repeating: 0, count: 16))
    return bytes
  }

  func decode(_ bytes: Data, teamKey: Data) throws -> DirectMessagePlaintext {
    guard bytes.count > 29 + 16 else { throw LeafError.directMessageBlobMalformed }
    let start = bytes.index(bytes.startIndex, offsetBy: 29)
    let end = bytes.index(bytes.endIndex, offsetBy: -16)
    let jsonSlice = bytes[start..<end]
    return try JSONDecoder().decode(DirectMessagePlaintext.self, from: Data(jsonSlice))
  }
}
