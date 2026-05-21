// Track 5 / S7 E.3 + E.4 — SupabaseClient workspace mutation tests.
// Mirrors SupabaseClientFetchCrossPostLogTests mock URLProtocol bootstrap pattern.

import CryptoKit
import XCTest

@testable import LeafCore

final class SupabaseClientWorkspaceMutationsTests: XCTestCase {
  private let baseURL = URL(string: "https://test.supabase.co")!
  private let anonKey = "test-anon-key"
  private let pubkey = String(repeating: "42", count: 32)
  private let userID = "00000000-0000-0000-0000-000000000fff"

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

  private func wrapWithBootstrap(
    _ next: @escaping @Sendable (URLRequest, Data) -> (HTTPURLResponse, Data)
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
      return (
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    try await client.patchWorkspaceName(id: wsID, name: "New Name")

    let url: URL = try XCTUnwrap(capturedURL)
    XCTAssertEqual(capturedMethod, "PATCH")
    XCTAssertEqual(url.path, "/rest/v1/workspaces")
    let query = url.query ?? ""
    XCTAssertTrue(
      query.contains("id=eq.\(wsID)"), "URL query should contain id=eq.<wsID>, got: \(query)")
  }

  // MARK: - patchWorkspaceName — Body

  func testPatchWorkspaceName_SendsCorrectBody() async throws {
    nonisolated(unsafe) var capturedBody: Data?
    MockURLProtocol.handler = wrapWithBootstrap { request, body in
      if request.url?.path == "/rest/v1/workspaces" {
        capturedBody = body
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
        Data()
      )
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
      return (
        HTTPURLResponse(
          url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
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
      return (
        HTTPURLResponse(
          url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
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
      return (
        HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
        Data(#"{"message":"permission denied"}"#.utf8)
      )
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
      return (
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
        Data()
      )
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
      return (
        HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
        Data(#"{"message":"permission denied"}"#.utf8)
      )
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
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 204,
          httpVersion: nil,
          headerFields: ["Content-Range": "*/0"]
        )!,
        Data()
      )
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
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 204,
          httpVersion: nil,
          headerFields: ["Content-Range": "*/0"]
        )!,
        Data()
      )
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
      return (
        HTTPURLResponse(
          url: request.url!,
          statusCode: 204,
          httpVersion: nil,
          headerFields: ["Content-Range": "0-0/1"]
        )!,
        Data()
      )
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
      return (
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    try await client.patchWorkspaceName(id: "ws-id", name: "Valid")
  }

  // MARK: - M027 insertWorkspace — URL + method

  /// Round-7 dogfooding fix (commit 9b2a744) — `WorkspaceReader.createWorkspace`
  /// becomes async and calls `SupabaseClient.insertWorkspace` after the local
  /// commit so the server-side `is_workspace_admin` RLS helper can find a
  /// row keyed by `created_by_pubkey` on subsequent admin operations (invite
  /// token writes, etc.). Pre-fix the workspaces table was server-side empty
  /// for any admin-created workspace, so every invite generation 403'd.

  func testInsertWorkspace_SendsPOSTToWorkspacesEndpoint() async throws {
    let wsID = "00000000-0000-0000-0000-000000000bbb"
    let adminPubkey = pubkey
    nonisolated(unsafe) var capturedURL: URL?
    nonisolated(unsafe) var capturedMethod: String?
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      if request.url?.path == "/rest/v1/workspaces" {
        capturedURL = request.url
        capturedMethod = request.httpMethod
      }
      let echo = """
        [{ "id": "\(wsID)", "name": "TestRoom",
           "created_by_pubkey": "\(adminPubkey)",
           "created_at": "2026-05-22T12:00:00Z" }]
        """.data(using: .utf8)!
      return (
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
        echo
      )
    }
    let client = makeClient()
    try await client.insertWorkspace(id: wsID, name: "TestRoom", createdByPubkey: pubkey)

    let url: URL = try XCTUnwrap(capturedURL)
    XCTAssertEqual(capturedMethod, "POST")
    XCTAssertEqual(url.path, "/rest/v1/workspaces")
    // INSERT goes to bare /rest/v1/workspaces with no ?id=eq.<id> filter
    // (unlike PATCH variants in this file) — server generates / accepts
    // the row id from the body.
    XCTAssertTrue(
      url.query == nil || url.query?.isEmpty == true,
      "insertWorkspace URL should have no query string, got: \(url.query ?? "nil")")
  }

  // MARK: - M027 insertWorkspace — Body

  func testInsertWorkspace_SendsCorrectBodyAndPostgrestHeaders() async throws {
    let wsID = "00000000-0000-0000-0000-000000000bbb"
    nonisolated(unsafe) var capturedBody: Data?
    nonisolated(unsafe) var capturedPrefer: String?
    nonisolated(unsafe) var capturedAuth: String?
    MockURLProtocol.handler = wrapWithBootstrap { request, body in
      if request.url?.path == "/rest/v1/workspaces" {
        capturedBody = body
        capturedPrefer = request.value(forHTTPHeaderField: "Prefer")
        capturedAuth = request.value(forHTTPHeaderField: "Authorization")
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    try await client.insertWorkspace(id: wsID, name: "TestRoom", createdByPubkey: pubkey)

    let body: Data = try XCTUnwrap(capturedBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    XCTAssertEqual(json?["id"] as? String, wsID)
    XCTAssertEqual(json?["name"] as? String, "TestRoom")
    XCTAssertEqual(
      json?["created_by_pubkey"] as? String, pubkey,
      "body must carry the admin pubkey for RLS WITH CHECK comparison")

    // PostgREST INSERT requires Prefer: return=representation so the server
    // echoes the row back (matches postgrestInsertHeaders helper).
    XCTAssertEqual(capturedPrefer, "return=representation")
    XCTAssertTrue((capturedAuth ?? "").hasPrefix("Bearer "))
  }

  // MARK: - M027 insertWorkspace — Name trim + validation

  func testInsertWorkspace_TrimsWhitespaceFromName() async throws {
    nonisolated(unsafe) var capturedBody: Data?
    MockURLProtocol.handler = wrapWithBootstrap { request, body in
      if request.url?.path == "/rest/v1/workspaces" {
        capturedBody = body
      }
      return (
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    try await client.insertWorkspace(id: "ws-id", name: "  Padded Room  ", createdByPubkey: pubkey)

    let body: Data = try XCTUnwrap(capturedBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    XCTAssertEqual(
      json?["name"] as? String, "Padded Room",
      "leading/trailing whitespace must be stripped before posting")
  }

  func testInsertWorkspace_EmptyName_ThrowsInvalidPayload_NoNetwork() async throws {
    MockURLProtocol.handler = { _, _ in
      XCTFail("should not fire network when name is empty")
      return (
        HTTPURLResponse(
          url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    do {
      try await client.insertWorkspace(id: "ws-id", name: "", createdByPubkey: pubkey)
      XCTFail("expected throw on empty name")
    } catch let err as LeafError {
      XCTAssertEqual(err, .invalidPayload)
    }
  }

  func testInsertWorkspace_WhitespaceOnlyName_ThrowsInvalidPayload_NoNetwork() async throws {
    MockURLProtocol.handler = { _, _ in
      XCTFail("should not fire network when name is only whitespace")
      return (
        HTTPURLResponse(
          url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    do {
      try await client.insertWorkspace(id: "ws-id", name: "   \t\n  ", createdByPubkey: pubkey)
      XCTFail("expected throw on whitespace-only name")
    } catch let err as LeafError {
      XCTAssertEqual(err, .invalidPayload)
    }
  }

  func testInsertWorkspace_NameOver80Chars_ThrowsInvalidPayload_NoNetwork() async throws {
    MockURLProtocol.handler = { _, _ in
      XCTFail("should not fire network when name exceeds 80-char cap")
      return (
        HTTPURLResponse(
          url: URL(string: "https://unused")!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    let longName = String(repeating: "x", count: 81)
    do {
      try await client.insertWorkspace(id: "ws-id", name: longName, createdByPubkey: pubkey)
      XCTFail("expected throw on too-long name")
    } catch let err as LeafError {
      XCTAssertEqual(err, .invalidPayload)
    }
  }

  /// 80-char boundary — exactly 80 chars after trim must NOT throw. Mirrors
  /// the `WorkspaceService.updateName` validation invariant.
  func testInsertWorkspace_NameExactly80Chars_DoesNotThrow() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    let exactly80 = String(repeating: "y", count: 80)
    // No throw == success.
    try await client.insertWorkspace(id: "ws-id", name: exactly80, createdByPubkey: pubkey)
  }

  // MARK: - M027 insertWorkspace — 409 conflict (UNIQUE name violation)

  /// Server-side `workspaces_name_per_admin_unique` UNIQUE(created_by_pubkey, name)
  /// is the same constraint the client mirrors with its case-insensitive
  /// pre-check. Re-creating a row after a prior attempt that synced but never
  /// refreshed local state — or a duplicate-name race against a sibling
  /// device — surfaces as 409 → `SupabaseError.conflict`. WorkspaceReader
  /// treats this as success (the row is on the server) so the user isn't
  /// stuck in a generate-loop.
  func testInsertWorkspace_409Conflict_ThrowsSupabaseConflict() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!,
        Data(#"{"message":"duplicate key value violates unique constraint"}"#.utf8)
      )
    }
    let client = makeClient()
    do {
      try await client.insertWorkspace(id: "ws-dup", name: "DupName", createdByPubkey: pubkey)
      XCTFail("expected throw on 409 conflict")
    } catch SupabaseError.conflict {
      // pass
    } catch {
      XCTFail("expected SupabaseError.conflict, got \(error)")
    }
  }

  // MARK: - M027 insertWorkspace — 403 Forbidden (RLS denial / impersonation)

  /// `workspaces_admin_write` RLS WITH CHECK gates `created_by_pubkey ==
  /// JWT pubkey claim`. A 403 here means the body's `created_by_pubkey` did
  /// NOT match the authenticated session's pubkey claim — defence-in-depth
  /// against impersonation by a compromised relay. Same mapping as the
  /// PATCH variants above.
  func testInsertWorkspace_403Forbidden_ThrowsForbidden() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
        Data(#"{"message":"new row violates row-level security policy"}"#.utf8)
      )
    }
    let client = makeClient()
    do {
      try await client.insertWorkspace(
        id: "ws-id", name: "RoomX",
        createdByPubkey: String(repeating: "f", count: 64))
      XCTFail("expected throw on 403")
    } catch SupabaseError.forbidden {
      // pass
    } catch {
      XCTFail("expected SupabaseError.forbidden, got \(error)")
    }
  }

  // MARK: - M027 insertWorkspace — non-201 success codes treated as errors

  /// Contrast to PATCH which accepts both 200 + 204 — INSERT specifically
  /// requires 201 Created. A 200 from PostgREST INSERT is unexpected (would
  /// only happen on `merge-duplicates` Prefer header which insertWorkspace
  /// does NOT set), so the client surfaces it as `.unexpected(status: 200)`
  /// to keep failure modes observable rather than silently treating it as
  /// success.
  func testInsertWorkspace_200_TreatedAsUnexpectedError() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    do {
      try await client.insertWorkspace(id: "ws-id", name: "RoomX", createdByPubkey: pubkey)
      XCTFail("expected throw on non-201 status")
    } catch let err as SupabaseError {
      // 200 is not in fromStatus' explicit list → .unexpected(status: 200)
      if case .unexpected(let status) = err {
        XCTAssertEqual(status, 200)
      } else {
        XCTFail("expected .unexpected(200), got \(err)")
      }
    }
  }

  func testInsertWorkspace_500_ThrowsServerError() async throws {
    MockURLProtocol.handler = wrapWithBootstrap { request, _ in
      return (
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
        Data()
      )
    }
    let client = makeClient()
    do {
      try await client.insertWorkspace(id: "ws-id", name: "RoomX", createdByPubkey: pubkey)
      XCTFail("expected throw on 500")
    } catch SupabaseError.serverError {
      // pass
    } catch {
      XCTFail("expected SupabaseError.serverError, got \(error)")
    }
  }
}
