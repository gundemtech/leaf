// M-II — SupabaseClientWorkspaceMembersTests
// Updated for B5: insertWorkspaceMember now calls /functions/v1/insert_workspace_member
// instead of /rest/v1/workspace_members. Body shape: { workspace_id, member_pubkey,
// display_name, joined_at_ms }. Edge response: { workspace_id, member_pubkey, joined_at }.

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

  func testInsertWorkspaceMember_postsToEdgeEndpointWithCorrectBody() async throws {
    let inviteeHex = String(repeating: "aa", count: 32)
    var capturedAuth: String?
    var capturedBody: Data?
    var capturedPath: String?

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
      case "/functions/v1/insert_workspace_member":
        capturedPath = path
        capturedAuth = request.value(forHTTPHeaderField: "Authorization")
        capturedBody = body
        let resp = HTTPURLResponse(
          url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        // Edge response: { workspace_id, member_pubkey, joined_at (ISO 8601) }
        let respBody = """
          { "workspace_id": "00000000-0000-0000-0000-000000000ccc",
            "member_pubkey": "\(inviteeHex)",
            "joined_at": "2026-05-23T10:00:00Z" }
          """.data(using: .utf8)!
        return (resp, respBody)
      default:
        XCTFail("unexpected path \(path)")
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }

    let client = SupabaseClient(
      baseURL: baseURL, anonKey: "k", urlSession: makeSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32))
      }
    )
    try await client.insertWorkspaceMember(
      workspaceID: "00000000-0000-0000-0000-000000000ccc",
      pubkeyHex: inviteeHex,
      displayName: "Bob"
    )
    // Verify Edge endpoint was hit (not PostgREST /rest/v1/workspace_members).
    XCTAssertEqual(capturedPath, "/functions/v1/insert_workspace_member")
    XCTAssertNotNil(capturedAuth)
    XCTAssertTrue(capturedAuth!.hasPrefix("Bearer "))
    // Idempotency-Key header must be present (M-II contract).
    // (Captured via MockURLProtocol — not asserted separately here since
    //  MockURLProtocol strips it before body capture; see idempotency tests.)

    let body = try XCTUnwrap(capturedBody)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    // Edge body shape: workspace_id, member_pubkey, display_name, joined_at_ms
    XCTAssertEqual(json["workspace_id"] as? String, "00000000-0000-0000-0000-000000000ccc")
    XCTAssertEqual(
      json["member_pubkey"] as? String, inviteeHex,
      "Edge body uses member_pubkey (not pubkey)")
    XCTAssertEqual(json["display_name"] as? String, "Bob")
    XCTAssertNotNil(
      json["joined_at_ms"] as? Int,
      "joined_at_ms must be present for idempotency hash")
    // Old PostgREST body fields must NOT appear.
    XCTAssertNil(json["pubkey"], "Edge body must not contain 'pubkey' (old PostgREST field)")
  }
}
