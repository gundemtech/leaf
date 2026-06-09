import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientPostInviteTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon"

  override func tearDown() async throws { MockURLProtocol.handler = nil }

  private func makeSession() -> URLSession {
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

  private func bootstrapResponses(
    adminPubkey: String,
    postInviteHandler: @escaping (URLRequest, Data) -> (HTTPURLResponse, Data)
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
      case "/rest/v1/invites":
        return postInviteHandler(request, body)
      default:
        XCTFail("unexpected \(path)")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
  }

  func testPostInvite_writesToInvitesTable_returnsToken() async throws {
    let workspaceID = "00000000-0000-0000-0000-000000000aaa"
    let adminHex = String(repeating: "42", count: 32)
    let blobBytes = Data(repeating: 0xDE, count: 64)
    let expiresAt = Date(timeIntervalSince1970: 9_999_000_000)

    var capturedBody: Data?
    var capturedHeaders: [String: String] = [:]
    bootstrapResponses(adminPubkey: adminHex) { request, body in
      capturedBody = body
      capturedHeaders["Authorization"] = request.value(forHTTPHeaderField: "Authorization") ?? ""
      capturedHeaders["Prefer"] = request.value(forHTTPHeaderField: "Prefer") ?? ""
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
      let respBody = """
        [{ "token": "11111111-1111-1111-1111-111111111111",
           "workspace_id": "\(workspaceID)",
           "expires_at": "2286-11-20T17:46:40Z" }]
        """.data(using: .utf8)!
      return (resp, respBody)
    }

    let seedDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-postinvite-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
    let seedStore = SupabaseSessionStore(at: seedDir)
    // Phase 1 (account-login) — anonymous bootstrap removed; seed a persisted
    // refresh-token so ensureAuthenticated() takes the persisted-refresh path
    // (served by the bootstrap helper's /auth/v1/token branch) instead of anon signup.
    try? seedStore.write(
      PersistedSession(
        refreshToken: "seed-rt",
        userID: "00000000-0000-0000-0000-000000000222", savedAtMs: 1))
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
      },
      sessionStore: seedStore
    )
    let issued = try await client.postInvite(
      workspaceID: workspaceID,
      adminPubkeyHex: adminHex,
      encryptedTeamkey: blobBytes,
      expiresAt: expiresAt,
      requireOTP: false,
      otpHashBase64: nil
    )
    XCTAssertEqual(issued.tokenBase64URL.count, 22)
    XCTAssertEqual(issued.tokenUUID, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    XCTAssertTrue((capturedHeaders["Authorization"] ?? "").hasPrefix("Bearer "))
    XCTAssertEqual(capturedHeaders["Prefer"], "return=representation")
    XCTAssertNotNil(capturedBody)

    let json = try JSONSerialization.jsonObject(with: capturedBody!) as! [String: Any]
    XCTAssertEqual(json["workspace_id"] as? String, workspaceID)
    XCTAssertEqual(json["admin_pubkey"] as? String, adminHex)
    XCTAssertEqual(json["require_otp"] as? Bool, false)
    // otp_hash absent or null when requireOTP=false
    XCTAssertNil(json["otp_hash"] as? String)
    let teamkeyHex = json["encrypted_teamkey"] as! String
    XCTAssertTrue(teamkeyHex.hasPrefix("\\x"))
    XCTAssertEqual(teamkeyHex.count, 2 + 64 * 2)  // \x + 64 bytes hex
  }

  func testPostInvite_withOTP_includesHash() async throws {
    let workspaceID = "00000000-0000-0000-0000-000000000bbb"
    let adminHex = String(repeating: "42", count: 32)
    let blobBytes = Data(repeating: 0xAB, count: 48)
    let otpHash = Data(repeating: 0xFF, count: 32).base64EncodedString()

    var capturedBody: Data?
    bootstrapResponses(adminPubkey: adminHex) { request, body in
      capturedBody = body
      let resp = HTTPURLResponse(
        url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
      let respBody =
        #"[{ "token": "22222222-2222-2222-2222-222222222222", "workspace_id": "\#(workspaceID)", "expires_at": "2286-11-20T17:46:40Z" }]"#
        .data(using: .utf8)!
      return (resp, respBody)
    }

    let seedDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-postinvite-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
    let seedStore = SupabaseSessionStore(at: seedDir)
    // Phase 1 (account-login) — anonymous bootstrap removed; seed a persisted
    // refresh-token so ensureAuthenticated() takes the persisted-refresh path
    // (served by the bootstrap helper's /auth/v1/token branch) instead of anon signup.
    try? seedStore.write(
      PersistedSession(
        refreshToken: "seed-rt",
        userID: "00000000-0000-0000-0000-000000000222", savedAtMs: 1))
    let client = SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
      },
      sessionStore: seedStore
    )
    _ = try await client.postInvite(
      workspaceID: workspaceID,
      adminPubkeyHex: adminHex,
      encryptedTeamkey: blobBytes,
      expiresAt: Date(),
      requireOTP: true,
      otpHashBase64: otpHash
    )
    let json = try JSONSerialization.jsonObject(with: capturedBody!) as! [String: Any]
    XCTAssertEqual(json["require_otp"] as? Bool, true)
    let otpHashWire = json["otp_hash"] as? String
    XCTAssertNotNil(otpHashWire)
    XCTAssertTrue(otpHashWire!.hasPrefix("\\x"))
  }

  func testUUIDBase64URLRoundTrip() {
    let original = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let encoded = original.base64URLString
    XCTAssertEqual(encoded.count, 22)
    let decoded = UUID(base64URLString: encoded)
    XCTAssertEqual(decoded, original)
  }

  func testUUIDBase64URLDecode_invalid_returnsNil() {
    XCTAssertNil(UUID(base64URLString: "too-short"))
    XCTAssertNil(UUID(base64URLString: "!!@#$%^&*()_+notvalid22"))
  }
}
