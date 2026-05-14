import XCTest
import CryptoKit
@testable import LeafCore

final class SupabaseClientResolveTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "anon"

    override func tearDown() async throws { MockURLProtocol.handler = nil }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient() -> SupabaseClient {
        SupabaseClient(baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
                       identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)) })
    }

    func testResolveInvite_success_decodesResponse() async throws {
        let tokenUUID = "abc0def1-2345-6789-abcd-ef0123456789"
        // Sample blob bytes encoded as base64url-no-padding
        let blobBytes = Data(repeating: 0xCC, count: 48)
        let blobB64URL = blobBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let inviteePub = String(repeating: "ee", count: 32)
        let adminPub = String(repeating: "ad", count: 32)

        MockURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/functions/v1/invite_resolve")
            XCTAssertEqual(request.httpMethod, "POST")
            // No Authorization header — token is the auth
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            // apikey IS required by Supabase production gateway, even on anon endpoints.
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon")
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["token"] as? String, tokenUUID)
            XCTAssertEqual(json?["invitee_pubkey"] as? String, inviteePub)

            let response = """
            {
              "encrypted_teamkey": "\(blobB64URL)",
              "admin_pubkey": "\(adminPub)",
              "workspace_id": "00000000-0000-0000-0000-000000000bbb",
              "workspace_name": "Acme",
              "require_otp": false,
              "expires_at": "2026-05-16T00:00:00Z"
            }
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let client = makeClient()
        let resolved = try await client.resolveInvite(token: tokenUUID, inviteePubkeyHex: inviteePub)
        XCTAssertEqual(resolved.workspaceID, "00000000-0000-0000-0000-000000000bbb")
        XCTAssertEqual(resolved.workspaceName, "Acme")
        XCTAssertEqual(resolved.adminPubkey, adminPub)
        XCTAssertFalse(resolved.requireOTP)
        XCTAssertEqual(resolved.encryptedTeamkey, blobBytes)
    }

    func testResolveInvite_404_throwsNotResolvable() async throws {
        MockURLProtocol.handler = { request, _ in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             #"{ "error": "not_resolvable" }"#.data(using: .utf8)!)
        }
        let client = makeClient()
        do {
            _ = try await client.resolveInvite(token: "44444444-4444-4444-4444-444444444444",
                                               inviteePubkeyHex: String(repeating: "ee", count: 32))
            XCTFail("expected throw")
        } catch let error as SupabaseError {
            XCTAssertEqual(error, .inviteNotResolvable)
        }
    }
}
