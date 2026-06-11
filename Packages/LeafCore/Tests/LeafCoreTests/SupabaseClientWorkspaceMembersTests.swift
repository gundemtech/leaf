import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientWorkspaceMembersTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!

  override func tearDown() async throws { MockURLProtocol.handler = nil }

  private func makeSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: c)
  }

  private func makeJWT(pubkey: String) -> String {
    let header = #"{"alg":"HS256","typ":"JWT"}"#
    let payload = #"{"pubkey":"\#(pubkey)","sub":"00000000-0000-0000-0000-0000000000c1"}"#
    func b64url(_ s: String) -> String {
      Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(header)).\(b64url(payload)).fake-sig"
  }

  func testInsertWorkspaceMember_postsRowWithJWT() async throws {
    let inviteeHex = String(repeating: "aa", count: 32)
    var capturedAuth: String?
    var capturedBody: Data?

    MockURLProtocol.handler = { request, body in
      let path = request.url?.path ?? ""
      switch path {
      case "/auth/v1/signup":
        let resp = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = """
          { "access_token": "t1", "refresh_token": "r1",
            "user": { "id": "00000000-0000-0000-0000-0000000000c1" },
            "expires_at": 9999999999 }
          """.data(using: .utf8)!
        return (resp, data)
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{ "ok": true }"#.data(using: .utf8)!
        )
      case "/auth/v1/token":
        let jwt = self.makeJWT(pubkey: inviteeHex)
        let resp = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = """
          { "access_token": "\(jwt)", "refresh_token": "r2",
            "user": { "id": "00000000-0000-0000-0000-0000000000c1" },
            "expires_at": 9999999999 }
          """.data(using: .utf8)!
        return (resp, data)
      case "/rest/v1/workspace_members":
        capturedAuth = request.value(forHTTPHeaderField: "Authorization")
        capturedBody = body
        let resp = HTTPURLResponse(
          url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        let respBody =
          #"[{ "workspace_id": "00000000-0000-0000-0000-000000000ccc", "pubkey": "\#(inviteeHex)", "display_name": "Bob" }]"#
          .data(using: .utf8)!
        return (resp, respBody)
      default:
        XCTFail("unexpected path \(path)")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }

    let seedDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-wsmem-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
    let seedStore = SupabaseSessionStore(at: seedDir)
    // Phase 1 (account-login) — anonymous bootstrap removed; seed a persisted
    // refresh-token so ensureAuthenticated() takes the persisted-refresh path
    // (served by the handler's /auth/v1/token branch) instead of anon signup.
    try? seedStore.write(
      PersistedSession(
        refreshToken: "seed-rt",
        userID: "00000000-0000-0000-0000-0000000000c1", savedAtMs: 1))
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: "k", urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
      },
      sessionStore: seedStore
    )
    try await client.insertWorkspaceMember(
      workspaceID: "00000000-0000-0000-0000-000000000ccc",
      pubkeyHex: inviteeHex,
      displayName: "Bob"
    )
    XCTAssertNotNil(capturedAuth)
    XCTAssertTrue(capturedAuth!.hasPrefix("Bearer "))
    let json = try JSONSerialization.jsonObject(with: capturedBody!) as! [String: Any]
    XCTAssertEqual(json["workspace_id"] as? String, "00000000-0000-0000-0000-000000000ccc")
    XCTAssertEqual(json["pubkey"] as? String, inviteeHex)
    XCTAssertEqual(json["display_name"] as? String, "Bob")
  }

  // MARK: - ensureWorkspaceMember (idempotent creator self-insert)

  /// Drives ensureWorkspaceMember against a workspace_members POST that
  /// returns `memberStatus`. Returns the thrown error (nil on success).
  private func runEnsure(memberStatus: Int) async -> Error? {
    let hex = String(repeating: "aa", count: 32)
    MockURLProtocol.handler = { request, _ in
      switch request.url?.path ?? "" {
      case "/auth/v1/signup":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{ "access_token": "t1", "refresh_token": "r1", "user": { "id": "00000000-0000-0000-0000-0000000000c1" }, "expires_at": 9999999999 }"#
            .data(using: .utf8)!
        )
      case "/functions/v1/register_pubkey":
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          #"{ "ok": true }"#.data(using: .utf8)!
        )
      case "/auth/v1/token":
        let jwt = self.makeJWT(pubkey: hex)
        return (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          "{ \"access_token\": \"\(jwt)\", \"refresh_token\": \"r2\", \"user\": { \"id\": \"00000000-0000-0000-0000-0000000000c1\" }, \"expires_at\": 9999999999 }"
            .data(using: .utf8)!
        )
      case "/rest/v1/workspace_members":
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: memberStatus, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      default:
        XCTFail("unexpected path \(request.url?.path ?? "")")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
    let seedDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-wsmem-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
    let seedStore = SupabaseSessionStore(at: seedDir)
    // Phase 1 (account-login) — anonymous bootstrap removed; seed a persisted
    // refresh-token so ensureAuthenticated() takes the persisted-refresh path
    // (served by the handler's /auth/v1/token branch) instead of anon signup.
    try? seedStore.write(
      PersistedSession(
        refreshToken: "seed-rt",
        userID: "00000000-0000-0000-0000-0000000000c1", savedAtMs: 1))
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: "k", urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
      },
      sessionStore: seedStore
    )
    do {
      try await client.ensureWorkspaceMember(
        workspaceID: "00000000-0000-0000-0000-000000000ccc", pubkeyHex: hex, displayName: "Bob")
      return nil
    } catch {
      return error
    }
  }

  func testEnsureWorkspaceMember_201_succeeds() async throws {
    let err = await runEnsure(memberStatus: 201)
    XCTAssertNil(err, "201 Created → success")
  }

  /// 409 = the (workspace_id, pubkey) member already exists (backfill / re-create /
  /// re-tick). An idempotent ensure must treat it as success, NOT throw.
  func testEnsureWorkspaceMember_409Conflict_treatedAsSuccess() async throws {
    let err = await runEnsure(memberStatus: 409)
    XCTAssertNil(err, "409 conflict must be swallowed as idempotent success")
  }

  func testEnsureWorkspaceMember_500_throws() async throws {
    let err = await runEnsure(memberStatus: 500)
    XCTAssertNotNil(err, "5xx is a real failure and must propagate")
  }
}
