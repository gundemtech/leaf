// Roster read-back: fetch server workspace_members + reconcile into local
// team_members so invitees see each other (not just {admin, self}).

import CryptoKit
import XCTest

@testable import LeafCore

final class WorkspaceRosterSyncServiceTests: XCTestCase {
  private var tempDir: URL!
  private var db: LeafCore.Database!
  private let workspaceID = "11111111-1111-1111-1111-111111111111"
  private let selfPub = String(repeating: "a", count: 64)
  private let alicePub = String(repeating: "b", count: 64)
  private let bobPub = String(repeating: "c", count: 64)

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-roster-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    db = try LeafCore.Database.openForWrite(
      at: tempDir.appendingPathComponent("events.sqlite"),
      config: .weakDefaults, encryption: .deterministicTest)
  }

  override func tearDown() async throws {
    db = nil
    MockURLProtocol.handler = nil
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeJWT(pubkey: String) -> String {
    func b64url(_ s: String) -> String {
      Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64url(#"{"alg":"HS256","typ":"JWT"}"#)).\(b64url(#"{"pubkey":"\#(pubkey)"}"#)).sig"
  }

  private func makeSession() -> SupabaseClient {
    // No-anonymous contract: seed a persisted refresh token so the client's
    // cold-start path refreshes via /auth/v1/token (mocked in wrapWithBootstrap)
    // instead of throwing .unauthorized.
    let dir = tempDir.appendingPathComponent("supa-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = SupabaseSessionStore(at: dir)
    try? store.write(
      PersistedSession(
        refreshToken: "seed-rt",
        userID: "00000000-0000-0000-0000-000000000000", savedAtMs: 1))
    return SupabaseClient(
      baseURL: URL(string: "https://test.supabase.co")!, anonKey: "k",
      urlSession: makeURLSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32))
      },
      sessionStore: store
    )
  }

  private func wrapWithBootstrap(
    pubkey: String,
    rest: @escaping @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)
  ) -> @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data) {
    let jwt = makeJWT(pubkey: pubkey)
    return { request, body in
      let path = request.url?.path ?? ""
      func ok(_ s: String) -> (HTTPURLResponse, Data) {
        (
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          Data(s.utf8)
        )
      }
      switch path {
      case "/auth/v1/signup":
        return ok(
          #"{"access_token":"t","refresh_token":"r","user":{"id":"00000000-0000-0000-0000-000000000000"},"expires_at":9999999999}"#
        )
      case "/functions/v1/register_pubkey":
        return ok(#"{"ok":true}"#)
      case "/auth/v1/token":
        return ok(
          #"{"access_token":"\#(jwt)","refresh_token":"r2","user":{"id":"00000000-0000-0000-0000-000000000000"},"expires_at":9999999999}"#
        )
      default:
        return try rest(request, body)
      }
    }
  }

  private func seedMember(pubkey: String, name: String, role: TeamMemberRole) throws {
    try db.insertTeamMember(
      TeamMember(
        id: UUID().uuidString.lowercased(), workspaceID: workspaceID, role: role,
        pubkeyHex: pubkey, displayName: name, addedAt: Date(timeIntervalSince1970: 1000),
        removedAt: nil))
  }

  func testSync_addsAbsentMembersFromServerRoster() async throws {
    // Local roster starts with only self (the admin) — the invitee-side gap.
    try seedMember(pubkey: selfPub, name: "Me", role: .admin)

    let wsID = workspaceID
    let sp = selfPub
    let bp = alicePub
    let cp = bobPub
    MockURLProtocol.handler = wrapWithBootstrap(pubkey: selfPub) { request, _ in
      guard request.url?.path == "/rest/v1/workspace_members" else {
        return (
          HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
      let json = """
        [{"workspace_id":"\(wsID)","pubkey":"\(sp)","display_name":"Me"},
         {"workspace_id":"\(wsID)","pubkey":"\(bp)","display_name":"Alice"},
         {"workspace_id":"\(wsID)","pubkey":"\(cp)","display_name":"Bob"}]
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }

    let svc = WorkspaceRosterSyncService(database: db, supabase: makeSession())
    let added = try await svc.sync(workspaceID: workspaceID)
    XCTAssertEqual(added, 2, "Alice + Bob added; self already present")

    let members = try db.readTeamMembers(workspaceID: workspaceID)
    XCTAssertEqual(Set(members.map { $0.displayName }), ["Me", "Alice", "Bob"])
    XCTAssertEqual(Set(members.map { $0.pubkeyHex }), [selfPub, alicePub, bobPub])
  }

  func testSync_idempotent_secondRunAddsNothing() async throws {
    try seedMember(pubkey: selfPub, name: "Me", role: .admin)
    let wsID = workspaceID
    let sp = selfPub
    let bp = alicePub
    MockURLProtocol.handler = wrapWithBootstrap(pubkey: selfPub) { request, _ in
      let json = """
        [{"workspace_id":"\(wsID)","pubkey":"\(sp)","display_name":"Me"},
         {"workspace_id":"\(wsID)","pubkey":"\(bp)","display_name":"Alice"}]
        """
      return (
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(json.utf8)
      )
    }
    let svc = WorkspaceRosterSyncService(database: db, supabase: makeSession())
    let first = try await svc.sync(workspaceID: workspaceID)
    let second = try await svc.sync(workspaceID: workspaceID)
    XCTAssertEqual(first, 1)
    XCTAssertEqual(second, 0)
    XCTAssertEqual(try db.readTeamMembers(workspaceID: workspaceID).count, 2)
  }
}
