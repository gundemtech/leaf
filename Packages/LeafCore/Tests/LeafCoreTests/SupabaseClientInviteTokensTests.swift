// M027 — SupabaseClient invite-token REST layer coverage.
//
// Uses MockURLProtocol to intercept /rest/v1/invite_tokens calls + the auth
// bootstrap chain (/auth/v1/signup + /functions/v1/register_pubkey +
// /auth/v1/token). Mirrors SupabaseClientPostInviteTests style.

import XCTest
import CryptoKit
@testable import LeafCore

final class SupabaseClientInviteTokensTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon"
    private let adminPubkey = String(repeating: "a", count: 64)
    private let workspaceID = "11111111-1111-1111-1111-111111111111"

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

    private func makeClient() -> SupabaseClient {
        SupabaseClient(
            baseURL: baseURL, anonKey: anonKey, urlSession: makeSession(),
            identity: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xAA, count: 32)) }
        )
    }

    /// Plays the auth bootstrap chain (signup → register_pubkey → token refresh
    /// with `pubkey` claim) so that `ensureAuthenticated()` returns a JWT with
    /// the expected pubkey claim, then delegates table calls to `tableHandler`.
    private func bootstrap(_ tableHandler: @escaping (URLRequest, Data) -> (HTTPURLResponse, Data)) {
        let refreshedJWT = makeJWT(pubkey: adminPubkey)
        MockURLProtocol.handler = { request, body in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                { "access_token": "tok-1", "refresh_token": "ref-1",
                  "user": { "id": "00000000-0000-0000-0000-000000000222" },
                  "expires_at": 9999999999 }
                """.data(using: .utf8)!
                return (resp, data)
            case "/functions/v1/register_pubkey":
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, #"{ "ok": true }"#.data(using: .utf8)!)
            case "/auth/v1/token":
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                { "access_token": "\(refreshedJWT)", "refresh_token": "ref-2",
                  "user": { "id": "00000000-0000-0000-0000-000000000222" },
                  "expires_at": 9999999999 }
                """.data(using: .utf8)!
                return (resp, data)
            case "/rest/v1/invite_tokens":
                return tableHandler(request, body)
            default:
                XCTFail("unexpected path \(path)")
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
    }

    // MARK: - insertInviteToken

    func testInsertInviteToken_PostsCorrectPayload_Returns201Echo() async throws {
        var capturedBody: Data?
        var capturedHeaders: [String: String] = [:]
        bootstrap { request, body in
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = body
            capturedHeaders["Authorization"] = request.value(forHTTPHeaderField: "Authorization") ?? ""
            capturedHeaders["Prefer"] = request.value(forHTTPHeaderField: "Prefer") ?? ""
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let respBody = """
            [{ "code": "LEAF-A8X7-B3K9-Q2N4",
               "workspace_id": "\(self.workspaceID)",
               "created_by_pubkey": "\(self.adminPubkey)",
               "label": "Team kickoff",
               "ttl_seconds": 86400,
               "expires_at": "2026-05-21T12:00:00Z",
               "max_uses": null,
               "used_count": 0,
               "deleted_at": null,
               "created_at": "2026-05-20T12:00:00Z" }]
            """.data(using: .utf8)!
            return (resp, respBody)
        }

        let client = makeClient()
        let token = InviteToken(
            code: "LEAF-A8X7-B3K9-Q2N4",
            workspaceID: workspaceID,
            createdByPubkeyHex: adminPubkey,
            label: "Team kickoff",
            ttlSeconds: 86400,
            expiresAt: Date(timeIntervalSince1970: 1_716_307_200),
            maxUses: nil,
            usedCount: 0,
            deletedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1_716_220_800)
        )
        let echoed = try await client.insertInviteToken(token)
        XCTAssertEqual(echoed.code, "LEAF-A8X7-B3K9-Q2N4")
        XCTAssertEqual(echoed.label, "Team kickoff")
        XCTAssertEqual(echoed.workspaceID, workspaceID)

        XCTAssertTrue((capturedHeaders["Authorization"] ?? "").hasPrefix("Bearer "))
        XCTAssertEqual(capturedHeaders["Prefer"], "return=representation")

        let body = try XCTUnwrap(capturedBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(parsed["code"] as? String, "LEAF-A8X7-B3K9-Q2N4")
        XCTAssertEqual(parsed["created_by_pubkey"] as? String, adminPubkey)
        XCTAssertEqual(parsed["ttl_seconds"] as? Int, 86400)
        XCTAssertEqual(parsed["label"] as? String, "Team kickoff")
    }

    func testInsertInviteToken_OmitsNilLabelAndMaxUses() async throws {
        var capturedBody: Data?
        bootstrap { request, body in
            capturedBody = body
            let resp = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let respBody = """
            [{ "code": "LEAF-T5K2-MJN3-WSK4",
               "workspace_id": "\(self.workspaceID)",
               "created_by_pubkey": "\(self.adminPubkey)",
               "label": null,
               "ttl_seconds": 0,
               "expires_at": null,
               "max_uses": null,
               "used_count": 0,
               "deleted_at": null,
               "created_at": "2026-05-20T12:00:00Z" }]
            """.data(using: .utf8)!
            return (resp, respBody)
        }
        let client = makeClient()
        let token = InviteToken(
            code: "LEAF-T5K2-MJN3-WSK4",
            workspaceID: workspaceID,
            createdByPubkeyHex: adminPubkey,
            label: nil,
            ttlSeconds: 0,
            expiresAt: nil,
            maxUses: nil,
            usedCount: 0,
            deletedAt: nil,
            createdAt: Date()
        )
        _ = try await client.insertInviteToken(token)

        let body = try XCTUnwrap(capturedBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(parsed["label"], "nil label should be omitted from JSON")
        XCTAssertNil(parsed["expires_at"], "nil expires_at should be omitted")
        XCTAssertNil(parsed["max_uses"], "nil max_uses should be omitted")
    }

    func testInsertInviteToken_403Forbidden_MapsToSupabaseError() async throws {
        bootstrap { request, body in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (resp, #"{ "error": "forbidden" }"#.data(using: .utf8)!)
        }
        let client = makeClient()
        let token = InviteToken(
            code: "LEAF-A8X7-B3K9-Q2N4",
            workspaceID: workspaceID, createdByPubkeyHex: adminPubkey,
            label: nil, ttlSeconds: 86400, expiresAt: Date(), maxUses: nil,
            usedCount: 0, deletedAt: nil, createdAt: Date()
        )
        do {
            _ = try await client.insertInviteToken(token)
            XCTFail("expected throw")
        } catch let error as SupabaseError {
            switch error {
            case .forbidden: break  // ok
            default: XCTFail("expected .forbidden, got \(error)")
            }
        }
    }

    // MARK: - listInviteTokens

    func testListInviteTokens_BuildsExpectedQueryAndDecodes() async throws {
        var capturedURL: URL?
        bootstrap { request, body in
            XCTAssertEqual(request.httpMethod, "GET")
            capturedURL = request.url
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let respBody = """
            [
              { "code": "LEAF-AAAA-BBBB-CCCC", "workspace_id": "\(self.workspaceID)",
                "created_by_pubkey": "\(self.adminPubkey)", "label": "Active1",
                "ttl_seconds": 86400, "expires_at": "2999-01-01T00:00:00Z",
                "max_uses": null, "used_count": 0, "deleted_at": null,
                "created_at": "2026-05-20T12:00:00Z" },
              { "code": "LEAF-DDDD-EEEE-FFFF", "workspace_id": "\(self.workspaceID)",
                "created_by_pubkey": "\(self.adminPubkey)", "label": "Deleted1",
                "ttl_seconds": 86400, "expires_at": "2026-05-20T13:00:00Z",
                "max_uses": null, "used_count": 0,
                "deleted_at": "2026-05-20T12:05:00Z",
                "created_at": "2026-05-20T12:00:00Z" }
            ]
            """.data(using: .utf8)!
            return (resp, respBody)
        }
        let client = makeClient()
        let tokens = try await client.listInviteTokens(workspaceID: workspaceID)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].label, "Active1")
        XCTAssertEqual(tokens[1].label, "Deleted1")
        XCTAssertNotNil(tokens[1].deletedAt)

        let url = try XCTUnwrap(capturedURL?.absoluteString)
        XCTAssertTrue(url.contains("workspace_id=eq.\(workspaceID)"))
        XCTAssertTrue(url.contains("order=created_at.desc"))
    }

    // MARK: - markInviteTokenDeleted

    func testMarkInviteTokenDeleted_PatchesDeletedAt() async throws {
        var capturedBody: Data?
        var capturedURL: URL?
        bootstrap { request, body in
            XCTAssertEqual(request.httpMethod, "PATCH")
            capturedURL = request.url
            capturedBody = body
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Content-Range": "0-0/1"]
            )!
            return (resp, Data())
        }
        let client = makeClient()
        try await client.markInviteTokenDeleted(code: "LEAF-AAAA-BBBB-CCCC")
        let url = try XCTUnwrap(capturedURL?.absoluteString)
        XCTAssertTrue(url.contains("code=eq.LEAF-AAAA-BBBB-CCCC"))
        let body = try XCTUnwrap(capturedBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(parsed["deleted_at"])
    }

    func testMarkInviteTokenDeleted_SilentZeroRows_MapsToNoRowsAffected() async throws {
        bootstrap { request, body in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Content-Range": "*/0"]
            )!
            return (resp, Data())
        }
        let client = makeClient()
        do {
            try await client.markInviteTokenDeleted(code: "LEAF-MISS-MISS-MISS")
            XCTFail("expected throw")
        } catch let error as SupabaseError {
            switch error {
            case .noRowsAffected: break  // ok
            default: XCTFail("expected .noRowsAffected, got \(error)")
            }
        }
    }
}
