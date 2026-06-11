// M027 — JoinRequestService coverage with real ECDH + recording crypto stubs.
//
// End-to-end: real LeafCore.Database (in-memory tempdir SQLCipher) + real
// SupabaseClient with MockURLProtocol-injected URLSession. Crypto layer
// uses RecordingInviteKDF / RecordingInviteBlobCodec stubs (same pattern as
// InviteServiceTests) — verifies the seal SHAPE (correct arguments, correct
// blob bytes captured) without depending on the moat ProdInviteBlobCodec.

import CryptoKit
import XCTest

@testable import LeafCore

final class JoinRequestServiceTests: XCTestCase {
  private var tempDir: URL!
  private var db: LeafCore.Database!
  private let workspaceID = "11111111-1111-1111-1111-111111111111"
  private let teamKeyID = "22222222-2222-2222-2222-222222222222"
  private let adminPubkey = String(repeating: "a", count: 64)
  private let inviteePubkey = String(repeating: "e", count: 64)
  /// Service identity (admin) private key bytes. Its derived pubkey is what
  /// m1 is seeded with, so `approve()` resolves self by pubkey.
  private let adminPrivBytes = Data(repeating: 0xBB, count: 32)
  private let anonKey = "test-anon"
  private let baseURL = URL(string: "https://test.supabase.co")!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-jr-svc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    db = try LeafCore.Database.openForWrite(
      at: tempDir.appendingPathComponent("events.sqlite"),
      config: .weakDefaults,
      encryption: .deterministicTest
    )
    // Seed workspace + admin member + active teamKey + teamKey bytes.
    // m1's pubkey == the service identity's derived pubkey so approve()
    // can resolve self by pubkey rather than list order.
    let adminSelfPubkey = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: adminPrivBytes
    ).publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    try db.writeSQL { raw in
      try raw.execute(
        sql: """
          INSERT INTO \(Schema.Workspaces.tableName)
              (\(Schema.Workspaces.id), \(Schema.Workspaces.name),
               \(Schema.Workspaces.createdAtMs), \(Schema.Workspaces.createdByMemberID))
          VALUES (?, 'TestRoom', 1700000000000, 'm1')
          """, arguments: [workspaceID])
      try raw.execute(
        sql: """
          INSERT INTO \(Schema.TeamMembers.tableName)
              (\(Schema.TeamMembers.id), \(Schema.TeamMembers.workspaceID),
               \(Schema.TeamMembers.role), \(Schema.TeamMembers.pubkeyHex),
               \(Schema.TeamMembers.displayName), \(Schema.TeamMembers.addedAtMs))
          VALUES ('m1', ?, 'admin', ?, 'Admin', 1700000000000)
          """, arguments: [workspaceID, adminSelfPubkey])
      try raw.execute(
        sql: """
          INSERT INTO \(Schema.TeamKeys.tableName)
              (\(Schema.TeamKeys.id), \(Schema.TeamKeys.workspaceID),
               \(Schema.TeamKeys.generatedAtMs),
               \(Schema.TeamKeys.generatedByMemberID))
          VALUES (?, ?, 1700000000000, 'm1')
          """, arguments: [teamKeyID, workspaceID])
    }
    let keystoreRoot = tempDir.appendingPathComponent("keystore")
    try FileManager.default.createDirectory(at: keystoreRoot, withIntermediateDirectories: true)
    let teamKeyBytes = Data(repeating: 0xCC, count: 32)
    try TeamKeystore.writeTeamKey(
      teamKeyBytes, workspaceID: workspaceID, keyID: teamKeyID, at: keystoreRoot
    )
  }

  override func tearDown() async throws {
    db = nil
    MockURLProtocol.handler = nil
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - URLSession + auth bootstrap

  private func makeURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeJWT(pubkey: String) -> String {
    let header = #"{"alg":"HS256","typ":"JWT"}"#
    let payload = #"{"pubkey":"\#(pubkey)","sub":"00000000-0000-0000-0000-000000000222"}"#
    func b64url(_ s: String) -> String {
      Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(header)).\(b64url(payload)).fake-sig"
  }

  private func bootstrap(
    approveHandler: ((URLRequest, Data) -> (HTTPURLResponse, Data))? = nil,
    declineHandler: ((URLRequest, Data) -> (HTTPURLResponse, Data))? = nil,
    cancelHandler: ((URLRequest, Data) -> (HTTPURLResponse, Data))? = nil,
    createHandler: ((URLRequest, Data) -> (HTTPURLResponse, Data))? = nil,
    deleteHandler: ((URLRequest, Data) -> (HTTPURLResponse, Data))? = nil,
    listPendingHandler: ((URLRequest) -> (HTTPURLResponse, Data))? = nil,
    fetchOwnHandler: ((URLRequest) -> (HTTPURLResponse, Data))? = nil
  ) {
    let refreshedJWT = makeJWT(pubkey: adminPubkey)
    MockURLProtocol.handler = { request, body in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        let resp = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = """
          { "access_token": "tok-1", "refresh_token": "ref-1",
            "user": { "id": "00000000-0000-0000-0000-000000000222" },
            "expires_at": 9999999999 }
          """.data(using: .utf8)!
        return (resp, data)
      case "/functions/v1/register_pubkey":
        let resp = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (resp, #"{ "ok": true }"#.data(using: .utf8)!)
      case "/auth/v1/token":
        let resp = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = """
          { "access_token": "\(refreshedJWT)", "refresh_token": "ref-2",
            "user": { "id": "00000000-0000-0000-0000-000000000222" },
            "expires_at": 9999999999 }
          """.data(using: .utf8)!
        return (resp, data)
      case "/functions/v1/create_join_request":
        return createHandler?(request, body) ?? (
          HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      case "/functions/v1/approve_join_request":
        return approveHandler?(request, body) ?? (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"ok": true}"#.data(using: .utf8)!
        )
      case "/functions/v1/decline_join_request":
        return declineHandler?(request, body) ?? (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"ok": true}"#.data(using: .utf8)!
        )
      case "/functions/v1/cancel_join_request":
        return cancelHandler?(request, body) ?? (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"ok": true}"#.data(using: .utf8)!
        )
      case "/functions/v1/delete_invite_token":
        return deleteHandler?(request, body) ?? (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{"ok": true}"#.data(using: .utf8)!
        )
      case "/rest/v1/join_requests":
        if request.httpMethod == "GET" {
          return listPendingHandler?(request)
            ?? fetchOwnHandler?(request)
            ?? (
              HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
              "[]".data(using: .utf8)!
            )
        }
        XCTFail("unexpected method on /rest/v1/join_requests: \(request.httpMethod ?? "?")")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      default:
        XCTFail("unexpected path \(path)")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
  }

  // Phase 1 (account-login) — anonymous bootstrap removed; seed a persisted
  // refresh-token so ensureAuthenticated() takes the persisted-refresh path
  // (served by the bootstrap helper's /auth/v1/token branch) instead of the
  // deleted anon signup.
  private func makeSupabase() -> SupabaseClient {
    let dir = tempDir.appendingPathComponent("supa-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = SupabaseSessionStore(at: dir)
    try? store.write(
      PersistedSession(
        refreshToken: "seed-rt",
        userID: "00000000-0000-0000-0000-000000000222", savedAtMs: 1))
    return SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeURLSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
      },
      sessionStore: store
    )
  }

  private func makeService(
    kdf: RecordingInviteKDF = RecordingInviteKDF(),
    codec: RecordingInviteBlobCodec = RecordingInviteBlobCodec(),
    supabase: SupabaseClient? = nil
  ) -> JoinRequestService {
    let keystoreRoot = tempDir.appendingPathComponent("keystore")
    let adminPrivBytes = self.adminPrivBytes
    return JoinRequestService(
      database: db,
      supabase: supabase ?? makeSupabase(),
      inviteKDF: kdf,
      inviteBlobCodec: codec,
      keystoreRoot: keystoreRoot,
      now: { Date(timeIntervalSince1970: 1_716_220_800) },
      identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: adminPrivBytes) }
    )
  }

  // MARK: - submit (invitee)

  func testSubmit_PostsCorrectPayloadAndDecodes201Response() async throws {
    var capturedBody: Data?
    bootstrap(createHandler: { request, body in
      capturedBody = body
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
      let respBody = """
        { "request_id": "33333333-3333-3333-3333-333333333333",
          "workspace_id": "\(self.workspaceID)",
          "code": "LEAF-A8X7-B3K9-Q2N4",
          "invitee_pubkey": "\(self.inviteePubkey)",
          "invitee_display_name": "Eve",
          "status": "pending",
          "encrypted_team_key": null,
          "created_at": "2026-05-20T12:00:00Z",
          "decided_at": null,
          "decided_by_pubkey": null }
        """.data(using: .utf8)!
      return (resp, respBody)
    })

    let service = makeService()
    let result = try await service.submit(
      workspaceID: workspaceID, code: "LEAF-A8X7-B3K9-Q2N4", displayName: "Eve"
    )
    XCTAssertEqual(result.status, .pending)
    XCTAssertEqual(result.inviteeDisplayName, "Eve")
    XCTAssertEqual(result.code, "LEAF-A8X7-B3K9-Q2N4")

    let body = try XCTUnwrap(capturedBody)
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(parsed["workspace_id"] as? String, workspaceID)
    XCTAssertEqual(parsed["code"] as? String, "LEAF-A8X7-B3K9-Q2N4")
    XCTAssertEqual(parsed["display_name"] as? String, "Eve")
  }

  // MARK: - approve (admin) — ECDH + seal verification

  func testApprove_PerformsECDHAndPostsEncryptedBlob() async throws {
    var capturedBody: Data?
    let kdf = RecordingInviteKDF()
    let codec = RecordingInviteBlobCodec()
    bootstrap(approveHandler: { request, body in
      capturedBody = body
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (resp, #"{"ok": true}"#.data(using: .utf8)!)
    })

    let service = makeService(kdf: kdf, codec: codec)
    try await service.approve(
      workspaceID: workspaceID,
      requestID: "33333333-3333-3333-3333-333333333333",
      inviteePubkeyHex: inviteePubkey,
      inviteeDisplayName: "Eve"
    )

    // KDF received ECDH shared secret + empty OTP (closed-mode invite).
    XCTAssertEqual(kdf.calls.count, 1)
    let kdfCall = try XCTUnwrap(kdf.calls.first)
    XCTAssertEqual(kdfCall.otp, "")

    // Codec received plaintext with right shape + correct admin pub embed.
    XCTAssertEqual(codec.encodeCalls.count, 1)
    let encodeCall = try XCTUnwrap(codec.encodeCalls.first)
    XCTAssertEqual(encodeCall.plaintext.orgID, workspaceID)
    XCTAssertEqual(encodeCall.plaintext.orgName, "TestRoom")
    XCTAssertEqual(encodeCall.plaintext.teamKeyID, teamKeyID)
    // teamKey base64 — verify it decodes to the seeded teamKey bytes.
    let decodedTeamKey = Data(base64Encoded: encodeCall.plaintext.teamKeyBase64)
    XCTAssertEqual(decodedTeamKey, Data(repeating: 0xCC, count: 32))
    XCTAssertEqual(encodeCall.plaintext.adminMemberID, "m1")
    XCTAssertEqual(encodeCall.adminPubkey.count, 32)

    // POSTed body contains encrypted_team_key as base64 of the stub blob bytes.
    let body = try XCTUnwrap(capturedBody)
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(parsed["request_id"] as? String, "33333333-3333-3333-3333-333333333333")
    let posted = try XCTUnwrap(parsed["encrypted_team_key"] as? String)
    let postedBytes = try XCTUnwrap(Data(base64Encoded: posted))
    XCTAssertEqual(postedBytes, codec.stubBlob.bytes)
  }

  func testApprove_RejectsMalformedInviteePubkey() async throws {
    bootstrap()
    let service = makeService()
    do {
      try await service.approve(
        workspaceID: workspaceID,
        requestID: "33333333-3333-3333-3333-333333333333",
        inviteePubkeyHex: "SHORT",
        inviteeDisplayName: "Eve"
      )
      XCTFail("expected throw on malformed pubkey")
    } catch let error as LeafError {
      switch error {
      case .invalidPayload: break
      default: XCTFail("expected .invalidPayload, got \(error)")
      }
    }
  }

  // MARK: - approve (admin) — Bug B: local roster insert

  /// After approve succeeds, the invitee must appear in the admin's LOCAL
  /// team_members so the approving device's roster updates immediately
  /// (independent of the invitee's accept or any workspace_members read-back).
  func testApprove_InsertsInviteeIntoLocalRoster() async throws {
    bootstrap(approveHandler: { request, _ in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (resp, #"{"ok": true}"#.data(using: .utf8)!)
    })
    let service = makeService()
    try await service.approve(
      workspaceID: workspaceID,
      requestID: "33333333-3333-3333-3333-333333333333",
      inviteePubkeyHex: inviteePubkey,
      inviteeDisplayName: "Eve"
    )

    let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: false)
    let invitee = members.first { $0.pubkeyHex == inviteePubkey.lowercased() }
    XCTAssertNotNil(invitee, "approved invitee must be in the admin's local roster")
    XCTAssertEqual(invitee?.role, .member)
    XCTAssertEqual(invitee?.displayName, "Eve")
    XCTAssertEqual(members.count, 2, "admin (m1) + invitee")
  }

  /// Re-approve of the same request/pubkey must not duplicate the invitee
  /// (idempotent insert-if-absent by pubkey).
  func testApprove_ReApprove_NoDuplicateInvitee() async throws {
    bootstrap(approveHandler: { request, _ in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (resp, #"{"ok": true}"#.data(using: .utf8)!)
    })
    let service = makeService()
    for _ in 0..<2 {
      try await service.approve(
        workspaceID: workspaceID,
        requestID: "33333333-3333-3333-3333-333333333333",
        inviteePubkeyHex: inviteePubkey,
        inviteeDisplayName: "Eve"
      )
    }
    let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: true)
    XCTAssertEqual(
      members.filter { $0.pubkeyHex == inviteePubkey.lowercased() }.count, 1,
      "re-approve must not duplicate the invitee")
    XCTAssertEqual(members.count, 2)
  }

  // MARK: - decline / cancel / delete

  func testDecline_PostsToEdgeFunction() async throws {
    var capturedBody: Data?
    bootstrap(declineHandler: { request, body in
      capturedBody = body
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (resp, #"{"ok": true}"#.data(using: .utf8)!)
    })

    let service = makeService()
    try await service.decline(requestID: "44444444-4444-4444-4444-444444444444")
    let body = try XCTUnwrap(capturedBody)
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(parsed["request_id"] as? String, "44444444-4444-4444-4444-444444444444")
  }

  func testCancel_PostsToEdgeFunction() async throws {
    var capturedBody: Data?
    bootstrap(cancelHandler: { request, body in
      capturedBody = body
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (resp, #"{"ok": true}"#.data(using: .utf8)!)
    })

    let service = makeService()
    try await service.cancel(requestID: "55555555-5555-5555-5555-555555555555")
    let body = try XCTUnwrap(capturedBody)
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(parsed["request_id"] as? String, "55555555-5555-5555-5555-555555555555")
  }

  func testDeleteInviteToken_PostsToEdgeFunction() async throws {
    var capturedBody: Data?
    bootstrap(deleteHandler: { request, body in
      capturedBody = body
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (resp, #"{"ok": true}"#.data(using: .utf8)!)
    })

    let service = makeService()
    try await service.deleteInviteToken(code: "LEAF-A8X7-B3K9-Q2N4")
    let body = try XCTUnwrap(capturedBody)
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(parsed["code"] as? String, "LEAF-A8X7-B3K9-Q2N4")
  }

  // MARK: - listPending / fetchOwn

  func testListPending_DecodesAndOrders() async throws {
    bootstrap(listPendingHandler: { request in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = """
        [
          { "request_id": "aaaaaaaa-1111-1111-1111-111111111111",
            "workspace_id": "\(self.workspaceID)",
            "code": "LEAF-A8X7-B3K9-Q2N4",
            "invitee_pubkey": "\(self.inviteePubkey)",
            "invitee_display_name": "Eve",
            "status": "pending",
            "encrypted_team_key": null,
            "created_at": "2026-05-20T13:00:00Z",
            "decided_at": null,
            "decided_by_pubkey": null }
        ]
        """.data(using: .utf8)!
      return (resp, body)
    })

    let service = makeService()
    let pending = try await service.listPending(workspaceID: workspaceID)
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending[0].inviteeDisplayName, "Eve")
    XCTAssertEqual(pending[0].status, .pending)
  }

  func testFetchOwn_ReturnsApprovedRowWithBlob() async throws {
    bootstrap(fetchOwnHandler: { request in
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      let body = """
        [
          { "request_id": "aaaaaaaa-1111-1111-1111-111111111111",
            "workspace_id": "\(self.workspaceID)",
            "code": "LEAF-A8X7-B3K9-Q2N4",
            "invitee_pubkey": "\(self.inviteePubkey)",
            "invitee_display_name": "Eve",
            "status": "approved",
            "encrypted_team_key": "\\\\xdeadbeefcafe",
            "created_at": "2026-05-20T13:00:00Z",
            "decided_at": "2026-05-20T13:05:00Z",
            "decided_by_pubkey": "\(self.adminPubkey)" }
        ]
        """.data(using: .utf8)!
      return (resp, body)
    })

    let service = makeService()
    let row = try await service.fetchOwn(requestID: "aaaaaaaa-1111-1111-1111-111111111111")
    XCTAssertEqual(row?.status, .approved)
    XCTAssertNotNil(row?.encryptedTeamKey)
    XCTAssertEqual(row?.encryptedTeamKey?.count, 6)  // \xdeadbeefcafe = 6 bytes
    XCTAssertEqual(row?.decidedByPubkeyHex, adminPubkey)
  }
}

// MARK: - Recording crypto stubs (mirror InviteServiceTests pattern)

private final class RecordingInviteKDF: InviteKDF, @unchecked Sendable {
  var stubKey = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
  var calls: [(sharedSecret: SharedSecret, otp: String)] = []
  func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
    calls.append((sharedSecret, otp))
    return stubKey
  }
  func hashOTPForServerStorage(otp: String) -> Data { Data(repeating: 0xEF, count: 32) }
}

private final class RecordingInviteBlobCodec: InviteBlobCodec, @unchecked Sendable {
  var stubBlob = InviteBlob(bytes: Data([0x02] + (0..<60).map { _ in UInt8(0xCD) }))
  var encodeCalls: [(plaintext: InvitePlaintext, adminPubkey: Data, wrapKey: SymmetricKey)] = []
  func encode(_ plaintext: InvitePlaintext, adminPubkey: Data, wrapKey: SymmetricKey) throws
    -> InviteBlob
  {
    encodeCalls.append((plaintext, adminPubkey, wrapKey))
    return stubBlob
  }
  func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
    fatalError("JoinRequestService approve path doesn't decode")
  }
}
