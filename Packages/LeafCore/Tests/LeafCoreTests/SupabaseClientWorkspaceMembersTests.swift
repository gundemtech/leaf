import XCTest
import CryptoKit
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
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                { "access_token": "t1", "refresh_token": "r1",
                  "user": { "id": "00000000-0000-0000-0000-0000000000c1" },
                  "expires_at": 9999999999 }
                """.data(using: .utf8)!
                return (resp, data)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        #"{ "ok": true }"#.data(using: .utf8)!)
            case "/auth/v1/token":
                let jwt = self.makeJWT(pubkey: inviteeHex)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                { "access_token": "\(jwt)", "refresh_token": "r2",
                  "user": { "id": "00000000-0000-0000-0000-0000000000c1" },
                  "expires_at": 9999999999 }
                """.data(using: .utf8)!
                return (resp, data)
            case "/rest/v1/workspace_members":
                capturedAuth = request.value(forHTTPHeaderField: "Authorization")
                capturedBody = body
                let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
                let respBody = #"[{ "workspace_id": "00000000-0000-0000-0000-000000000ccc", "pubkey": "\#(inviteeHex)", "display_name": "Bob" }]"#.data(using: .utf8)!
                return (resp, respBody)
            default:
                XCTFail("unexpected path \(path)")
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let client = SupabaseClient(
            baseURL: baseURL, anonKey: "k", urlSession: makeSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32)) }
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
}
