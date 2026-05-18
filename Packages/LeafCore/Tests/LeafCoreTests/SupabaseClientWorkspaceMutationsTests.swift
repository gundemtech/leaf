// Track 5 / S7 E.3 + E.4 — SupabaseClient workspace mutation tests.
// Mirrors SupabaseClientFetchCrossPostLogTests mock URLProtocol bootstrap pattern.

import XCTest
import CryptoKit
@testable import LeafCore

final class SupabaseClientWorkspaceMutationsTests: XCTestCase {
    private let baseURL = URL(string: "https://test.supabase.co")!
    private let anonKey = "test-anon-key"
    private let pubkey  = String(repeating: "42", count: 32)
    private let userID  = "00000000-0000-0000-0000-000000000fff"

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
        let header  = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"pubkey":"\#(pubkey)","sub":"\#(userID)"}"#
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64url(header)).\(b64url(payload)).sig"
    }

    private func wrapWithBootstrap(
        _ next: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
    ) -> (@Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)) {
        let jwt = makeJWT()
        let uid = userID
        return { request, body in
            let path = request.url?.path ?? ""
            switch path {
            case "/auth/v1/signup":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "boot-tok", "refresh_token": "boot-rt",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            case "/functions/v1/register_pubkey":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(#"{"ok":true}"#.utf8))
            case "/auth/v1/token":
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        """
                        { "access_token": "\(jwt)", "refresh_token": "ref",
                          "user": { "id": "\(uid)" }, "expires_at": 9999999999 }
                        """.data(using: .utf8)!)
            default:
                return next(request, body)
            }
        }
    }

    private func makeClient() -> SupabaseClient {
        SupabaseClient(
            baseURL: baseURL, anonKey: anonKey,
            urlSession: makeSession(),
            identity: fixedIdentity()
        )
    }

    // MARK: - patchWorkspaceName — URL

    func testPatchWorkspaceName_SendsCorrectURL() async throws {
        let wsID = "test-workspace-id"
        nonisolated(unsafe) var capturedURL: URL?
        nonisolated(unsafe) var capturedMethod: String?
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            if request.url?.path == "/rest/v1/workspaces" {
                capturedURL = request.url
                capturedMethod = request.httpMethod
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeClient()
        try await client.patchWorkspaceName(id: wsID, name: "New Name")

        let url: URL = try XCTUnwrap(capturedURL)
        XCTAssertEqual(capturedMethod, "PATCH")
        XCTAssertEqual(url.path, "/rest/v1/workspaces")
        let query = url.query ?? ""
        XCTAssertTrue(query.contains("id=eq.\(wsID)"), "URL query should contain id=eq.<wsID>, got: \(query)")
    }

    // MARK: - patchWorkspaceName — Body

    func testPatchWorkspaceName_SendsCorrectBody() async throws {
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = wrapWithBootstrap { request, body in
            if request.url?.path == "/rest/v1/workspaces" {
                capturedBody = body
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeClient()
        try await client.patchWorkspaceName(id: "ws-id", name: "My Workspace")

        let body: Data = try XCTUnwrap(capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["name"] as? String, "My Workspace")
    }

    // MARK: - patchWorkspaceName — Validation

    func testPatchWorkspaceName_Empty_ThrowsInvalidPayload() async throws {
        MockURLProtocol.handler = { _, _ in
            XCTFail("should not fire network when name is empty")
            return (HTTPURLResponse(url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = makeClient()
        do {
            try await client.patchWorkspaceName(id: "ws-id", name: "")
            XCTFail("expected throw")
        } catch let err as LeafError {
            XCTAssertEqual(err, .invalidPayload)
        }
    }

    func testPatchWorkspaceName_TooLong_ThrowsInvalidPayload() async throws {
        MockURLProtocol.handler = { _, _ in
            XCTFail("should not fire network when name is too long")
            return (HTTPURLResponse(url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = makeClient()
        let longName = String(repeating: "x", count: 81)
        do {
            try await client.patchWorkspaceName(id: "ws-id", name: longName)
            XCTFail("expected throw")
        } catch let err as LeafError {
            XCTAssertEqual(err, .invalidPayload)
        }
    }

    // MARK: - patchWorkspaceName — 403 Forbidden

    func testPatchWorkspaceName_403Forbidden_ThrowsForbidden() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"message":"permission denied"}"#.utf8))
        }
        let client = makeClient()
        do {
            try await client.patchWorkspaceName(id: "ws-id", name: "Valid")
            XCTFail("expected throw")
        } catch SupabaseError.forbidden {
            // pass
        } catch {
            XCTFail("expected SupabaseError.forbidden, got \(error)")
        }
    }

    // MARK: - softDeleteWorkspace — Body

    func testSoftDeleteWorkspace_SendsCorrectBody() async throws {
        nonisolated(unsafe) var capturedBody: Data?
        let beforeMs = Int64(Date().timeIntervalSince1970 * 1000)
        MockURLProtocol.handler = wrapWithBootstrap { request, body in
            if request.url?.path == "/rest/v1/workspaces" {
                capturedBody = body
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeClient()
        try await client.softDeleteWorkspace(id: "ws-del-id")
        let afterMs = Int64(Date().timeIntervalSince1970 * 1000)

        let body: Data = try XCTUnwrap(capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let sentMs = try XCTUnwrap(json?["deleted_at_ms"] as? Int64)
        XCTAssertGreaterThanOrEqual(sentMs, beforeMs)
        XCTAssertLessThanOrEqual(sentMs, afterMs)
    }

    // MARK: - softDeleteWorkspace — 403 Forbidden

    func testSoftDeleteWorkspace_403Forbidden_ThrowsForbidden() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"message":"permission denied"}"#.utf8))
        }
        let client = makeClient()
        do {
            try await client.softDeleteWorkspace(id: "ws-id")
            XCTFail("expected throw")
        } catch SupabaseError.forbidden {
            // pass
        } catch {
            XCTFail("expected SupabaseError.forbidden, got \(error)")
        }
    }

    // MARK: - S7 Stage 6 fix C-I9 — silent-0-row RLS-deny detection

    /// PostgREST returns 204 with `Content-Range: */0` when an RLS USING-clause
    /// filters out the row (non-creator UPDATE on workspaces, etc.). Without
    /// the C-I9 fix the client treated this as success — local layer would
    /// happily UPDATE the workspace name while the server kept the old name.
    /// With the fix, the client throws `.noRowsAffected` which
    /// WorkspaceReader.userFacingMessage maps to the same "Only the workspace
    /// creator can perform this action" message as an explicit 403.
    func testPatchWorkspaceName_204WithZeroAffectedRows_ThrowsNoRowsAffected() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: ["Content-Range": "*/0"]
            )!,
            Data())
        }
        let client = makeClient()
        do {
            try await client.patchWorkspaceName(id: "ws-no-perm", name: "Hack")
            XCTFail("expected throw")
        } catch SupabaseError.noRowsAffected {
            // pass
        } catch {
            XCTFail("expected SupabaseError.noRowsAffected, got \(error)")
        }
    }

    func testSoftDeleteWorkspace_204WithZeroAffectedRows_ThrowsNoRowsAffected() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: ["Content-Range": "*/0"]
            )!,
            Data())
        }
        let client = makeClient()
        do {
            try await client.softDeleteWorkspace(id: "ws-no-perm")
            XCTFail("expected throw")
        } catch SupabaseError.noRowsAffected {
            // pass
        } catch {
            XCTFail("expected SupabaseError.noRowsAffected, got \(error)")
        }
    }

    /// Sanity: 204 with `Content-Range: 0-0/1` (one row affected) is still
    /// success — coalescing the count parse logic correctly.
    func testPatchWorkspaceName_204WithOneAffectedRow_Success() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: ["Content-Range": "0-0/1"]
            )!,
            Data())
        }
        let client = makeClient()
        try await client.patchWorkspaceName(id: "ws-ok", name: "Valid")
        // No throw == success.
    }

    /// Defensive: if Content-Range header is absent (older PostgREST or
    /// non-Supabase mocks), the client treats success as success and doesn't
    /// over-throw. Preserves back-compat with the pre-fix mock pattern in
    /// other tests above (which return 204 without a Content-Range header).
    func testPatchWorkspaceName_204WithoutContentRange_TreatedAsSuccess() async throws {
        MockURLProtocol.handler = wrapWithBootstrap { request, _ in
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                    Data())
        }
        let client = makeClient()
        try await client.patchWorkspaceName(id: "ws-id", name: "Valid")
    }
}
