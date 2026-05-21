// M027 — `JoinRequestService.acceptApproved` (invitee post-approval materialisation).
//
// Sibling test file to `JoinRequestServiceTests.swift` (admin-encode coverage).
// This file exercises the SYMMETRIC invitee-decode + workspace materialisation
// path that was the structural gap from round 6 (G4 smoke wasn't reachable
// without it). Real LeafCore.Database + MockURLProtocol mock for the
// best-effort `workspace_members` remote sync; crypto layer uses recording
// stubs that return a controllable plaintext so the test asserts the
// downstream DB / keystore effects without depending on the moat codec.

import CryptoKit
import XCTest

@testable import LeafCore

final class JoinRequestServiceAcceptApprovedTests: XCTestCase {
  private var tempDir: URL!
  private var db: LeafCore.Database!
  private var keystoreRoot: URL!

  /// 32B X25519 priv used as THIS device's identity in every test. The
  /// pubkey derived from it is what `acceptApproved`'s pre-condition
  /// matches against `request.inviteePubkeyHex`.
  private static let inviteePrivBytes = Data(repeating: 0x42, count: 32)
  /// Admin pubkey carried on the JoinRequest row (`decided_by_pubkey`).
  /// Distinct from the inviteePrivBytes-derived value.
  private let adminPubkeyHex = String(repeating: "a", count: 64)
  private let workspaceID = "99999999-9999-9999-9999-999999999999"
  private let teamKeyID = "55555555-5555-5555-5555-555555555555"
  private let adminMemberID = "admin-member-id"
  private let fixedSelfMemberID = "self-member-id"
  private let now = Date(timeIntervalSince1970: 1_716_220_800)
  private let anonKey = "test-anon"
  private let baseURL = URL(string: "https://test.supabase.co")!

  override func setUp() async throws {
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("leaf-acc-appr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    db = try LeafCore.Database.openForWrite(
      at: tempDir.appendingPathComponent("events.sqlite"),
      config: .weakDefaults,
      encryption: .deterministicTest
    )
    keystoreRoot = tempDir.appendingPathComponent("keystore")
    try FileManager.default.createDirectory(at: keystoreRoot, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    db = nil
    MockURLProtocol.handler = nil
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - Test infrastructure

  /// Network stub — accept bootstrap + 201 the workspace_members INSERT.
  /// All other endpoints XCTFail so a stray request from `acceptApproved`
  /// surfaces in the test report instead of silently passing.
  private func bootstrap(
    memberInsertHandler: ((URLRequest, Data) -> (HTTPURLResponse, Data))? = nil
  ) {
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
          { "access_token": "fake.jwt", "refresh_token": "ref-2",
            "user": { "id": "00000000-0000-0000-0000-000000000222" },
            "expires_at": 9999999999 }
          """.data(using: .utf8)!
        return (resp, data)
      case "/rest/v1/workspace_members":
        return memberInsertHandler?(request, body)
          ?? (
            HTTPURLResponse(
              url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
            Data()
          )
      default:
        XCTFail("unexpected path \(path) — acceptApproved shouldn't hit this endpoint")
        return (
          HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
          Data()
        )
      }
    }
  }

  private func makeURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeSupabase() -> SupabaseClient {
    SupabaseClient(
      baseURL: baseURL, anonKey: anonKey, urlSession: makeURLSession(),
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(
          rawRepresentation: JoinRequestServiceAcceptApprovedTests.inviteePrivBytes)
      }
    )
  }

  private func makeService(
    codec: RecordingDecoderCodec = RecordingDecoderCodec()
  ) -> JoinRequestService {
    // Capture stored properties into locals so the @Sendable closures
    // below don't pin `self` (non-Sendable XCTestCase) into the service.
    let capturedNow = self.now
    let capturedSelfMemberID = self.fixedSelfMemberID
    return JoinRequestService(
      database: db,
      supabase: makeSupabase(),
      inviteKDF: AcceptApprovedKDFStub(),
      inviteBlobCodec: codec,
      keystoreRoot: keystoreRoot,
      now: { capturedNow },
      identity: {
        try Curve25519.KeyAgreement.PrivateKey(
          rawRepresentation: JoinRequestServiceAcceptApprovedTests.inviteePrivBytes)
      },
      generateMemberID: { capturedSelfMemberID }
    )
  }

  /// Pubkey hex matching the fixed `inviteePrivBytes` identity — used to
  /// pass the defence-in-depth `request.inviteePubkeyHex == self` check.
  private func selfPubkeyHex() throws -> String {
    let priv = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: Self.inviteePrivBytes)
    return priv.publicKey.rawRepresentation
      .map { String(format: "%02x", $0) }.joined()
  }

  private func makeRequest(
    status: JoinRequest.Status = .approved,
    encryptedTeamKey: Data? = Data([0x05, 0xAA, 0xBB]),
    decidedByPubkeyHex: String? = nil,
    inviteePubkeyHex: String? = nil,
    workspaceID: String? = nil
  ) throws -> JoinRequest {
    let resolvedInviteePubkey = try inviteePubkeyHex ?? selfPubkeyHex()
    return JoinRequest(
      requestID: UUID().uuidString,
      workspaceID: workspaceID ?? self.workspaceID,
      code: "LEAF-A8X7-B3K9-Q2N4",
      inviteePubkeyHex: resolvedInviteePubkey,
      inviteeDisplayName: "Eve",
      status: status,
      encryptedTeamKey: encryptedTeamKey,
      createdAt: Date(timeIntervalSince1970: 1_716_220_000),
      decidedAt: status == .approved ? now : nil,
      decidedByPubkeyHex: decidedByPubkeyHex ?? adminPubkeyHex
    )
  }

  /// Plaintext that the recording codec emits on decode. Matches the
  /// JoinRequest workspaceID by default so the defence-in-depth cross-check
  /// passes; individual tests override `orgID` to exercise the mismatch path.
  private func makePlaintext(
    orgID: String? = nil,
    orgName: String = "TestRoom",
    teamKeyBase64: String? = nil
  ) -> InvitePlaintext {
    // Default to 32B of zeros (passes the base64 round-trip + length check).
    let bytes = Data(repeating: 0x00, count: 32)
    return InvitePlaintext(
      teamKeyBase64: teamKeyBase64 ?? bytes.base64EncodedString(),
      teamKeyID: teamKeyID,
      orgID: orgID ?? workspaceID,
      orgName: orgName,
      adminMemberID: adminMemberID,
      adminDisplayName: "Alice",
      issuedAtMs: Int64(now.timeIntervalSince1970 * 1000)
    )
  }

  // MARK: - 1-3. Pre-condition guards (status / blob / admin pubkey)

  func testAcceptApproved_StatusNotApproved_ThrowsInvalidPayload() async throws {
    bootstrap()
    let request = try makeRequest(status: .pending)
    do {
      _ = try await makeService().acceptApproved(request: request)
      XCTFail("expected throw")
    } catch LeafError.invalidPayload {
      // pass
    }
  }

  func testAcceptApproved_MissingEncryptedTeamKey_ThrowsInvalidPayload() async throws {
    bootstrap()
    // Approved status but blob is nil — server CHECK should prevent this
    // server-side, but the client guards defensively.
    let request = try makeRequest(encryptedTeamKey: nil)
    do {
      _ = try await makeService().acceptApproved(request: request)
      XCTFail("expected throw")
    } catch LeafError.invalidPayload {
      // pass
    }
  }

  func testAcceptApproved_MissingDecidedByPubkey_ThrowsInvalidPayload() async throws {
    bootstrap()
    // Construct the request directly — `makeRequest(decidedByPubkeyHex: nil)`
    // would fall back to the fixture admin pubkey via `??`, masking the
    // explicit-nil case we want to exercise.
    let request = JoinRequest(
      requestID: UUID().uuidString,
      workspaceID: workspaceID,
      code: "LEAF-A8X7-B3K9-Q2N4",
      inviteePubkeyHex: try selfPubkeyHex(),
      inviteeDisplayName: "Eve",
      status: .approved,
      encryptedTeamKey: Data([0x05, 0xAA, 0xBB]),
      createdAt: Date(timeIntervalSince1970: 1_716_220_000),
      decidedAt: now,
      decidedByPubkeyHex: nil
    )
    do {
      _ = try await makeService().acceptApproved(request: request)
      XCTFail("expected throw")
    } catch LeafError.invalidPayload {
      // pass
    }
  }

  // MARK: - 4. Defence-in-depth — invitee pubkey must match THIS device

  func testAcceptApproved_InviteePubkeyDoesntMatchSelf_ThrowsInvalidPayload() async throws {
    bootstrap()
    // Forge a request that claims a different invitee pubkey than what
    // this device's priv-key derives to. RLS self_read should prevent
    // this server-side, but a tampered local row path must fail closed.
    let otherInvitee = String(repeating: "f", count: 64)
    let request = try makeRequest(inviteePubkeyHex: otherInvitee)
    do {
      _ = try await makeService().acceptApproved(request: request)
      XCTFail("expected throw")
    } catch LeafError.invalidPayload {
      // pass
    }
  }

  // MARK: - 5. Defence-in-depth — blob workspace_id must match row's

  func testAcceptApproved_WorkspaceIDMismatch_ThrowsBlobMalformed() async throws {
    bootstrap()
    let codec = RecordingDecoderCodec()
    // Plaintext claims a workspace different from the request row's.
    // Catch even though decrypt succeeded — the server's row could be
    // mis-routed or tampered.
    codec.stubPlaintext = makePlaintext(orgID: "00000000-0000-0000-0000-000000000000")
    let request = try makeRequest()
    do {
      _ = try await makeService(codec: codec).acceptApproved(request: request)
      XCTFail("expected throw")
    } catch LeafError.inviteBlobMalformed {
      // pass
    }
  }

  // MARK: - 6. Fresh path — materialises workspace + admin + self + teamKey

  func testAcceptApproved_FreshPath_MaterialisesWorkspaceMembersAndKey() async throws {
    bootstrap()
    let codec = RecordingDecoderCodec()
    codec.stubPlaintext = makePlaintext()
    let request = try makeRequest()

    let accepted = try await makeService(codec: codec).acceptApproved(request: request)

    // Returned value type
    XCTAssertEqual(accepted.orgID, workspaceID)
    XCTAssertEqual(accepted.orgName, "TestRoom")
    XCTAssertEqual(accepted.teamKeyID, teamKeyID)
    XCTAssertEqual(accepted.selfMemberID, fixedSelfMemberID)

    // Workspace row
    let workspace = try db.readWorkspace(id: workspaceID)
    XCTAssertNotNil(workspace, "workspace row should exist")
    XCTAssertEqual(workspace?.name, "TestRoom")
    XCTAssertNil(workspace?.leftAt)

    // Both members present
    let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: false)
    XCTAssertEqual(members.count, 2, "fresh path inserts admin + self")
    let adminMember = members.first(where: { $0.role == .admin })
    let selfMember = members.first(where: { $0.role == .member })
    XCTAssertEqual(adminMember?.id, adminMemberID)
    XCTAssertEqual(adminMember?.pubkeyHex, adminPubkeyHex.lowercased())
    XCTAssertEqual(adminMember?.displayName, "Alice")
    XCTAssertEqual(selfMember?.id, fixedSelfMemberID)
    XCTAssertEqual(selfMember?.pubkeyHex, try selfPubkeyHex())
    XCTAssertEqual(selfMember?.displayName, "Eve")

    // TeamKey row
    let activeKey = try db.readActiveTeamKey(workspaceID: workspaceID)
    XCTAssertEqual(activeKey?.id, teamKeyID)

    // Keystore file on disk
    let keyFile =
      keystoreRoot
      .appendingPathComponent("workspaces", isDirectory: true)
      .appendingPathComponent(workspaceID, isDirectory: true)
      .appendingPathComponent("team-keys", isDirectory: true)
      .appendingPathComponent("\(teamKeyID).key", isDirectory: false)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: keyFile.path),
      "keystore-first write must land before DB inserts")
    let onDisk = try Data(contentsOf: keyFile)
    XCTAssertEqual(onDisk.count, 32, "AES-256 raw key is 32 bytes")
  }

  // MARK: - 7. Rejoin path — clears left_at + adds self, retains admin

  func testAcceptApproved_RejoinPath_ClearsLeftAtAndInsertsSelf() async throws {
    bootstrap()
    // Seed a workspace that the invitee previously LEFT (left_at_ms set).
    // team_members preserves the admin row (audit invariant). team_keys
    // preserves the prior version.
    try db.writeSQL { raw in
      try raw.execute(
        sql: """
          INSERT INTO \(Schema.Workspaces.tableName)
              (\(Schema.Workspaces.id), \(Schema.Workspaces.name),
               \(Schema.Workspaces.createdAtMs), \(Schema.Workspaces.createdByMemberID),
               \(Schema.Workspaces.leftAtMs))
          VALUES (?, 'TestRoom', 1700000000000, ?, 1715000000000)
          """, arguments: [workspaceID, adminMemberID])
      try raw.execute(
        sql: """
          INSERT INTO \(Schema.TeamMembers.tableName)
              (\(Schema.TeamMembers.id), \(Schema.TeamMembers.workspaceID),
               \(Schema.TeamMembers.role), \(Schema.TeamMembers.pubkeyHex),
               \(Schema.TeamMembers.displayName), \(Schema.TeamMembers.addedAtMs))
          VALUES (?, ?, 'admin', ?, 'Alice', 1700000000000)
          """, arguments: [adminMemberID, workspaceID, adminPubkeyHex.lowercased()])
      // Seed the TeamKey row so the rejoin's `insertTeamKeyIfAbsent`
      // exercises the «already present, idempotent» branch.
      try raw.execute(
        sql: """
          INSERT INTO \(Schema.TeamKeys.tableName)
              (\(Schema.TeamKeys.id), \(Schema.TeamKeys.workspaceID),
               \(Schema.TeamKeys.generatedAtMs),
               \(Schema.TeamKeys.generatedByMemberID))
          VALUES (?, ?, 1700000000000, ?)
          """, arguments: [teamKeyID, workspaceID, adminMemberID])
    }

    let codec = RecordingDecoderCodec()
    codec.stubPlaintext = makePlaintext()
    let request = try makeRequest()

    let accepted = try await makeService(codec: codec).acceptApproved(request: request)
    XCTAssertEqual(accepted.orgID, workspaceID)

    // left_at_ms cleared
    let workspace = try db.readWorkspace(id: workspaceID)
    XCTAssertNotNil(workspace)
    XCTAssertNil(workspace?.leftAt, "rejoin must clear leftAt")

    // admin preserved (not duplicated); self freshly inserted
    let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: false)
    XCTAssertEqual(members.count, 2, "rejoin path: admin (preserved) + self (new)")
    let admin = members.first(where: { $0.id == adminMemberID })
    let selfM = members.first(where: { $0.id == fixedSelfMemberID })
    XCTAssertEqual(admin?.role, .admin)
    XCTAssertEqual(selfM?.role, .member)
    XCTAssertEqual(selfM?.displayName, "Eve")
  }

  // MARK: - 8. Already-current path — workspace active + self already present

  func testAcceptApproved_AlreadyCurrent_ThrowsInviteAlreadyAccepted() async throws {
    bootstrap()
    // Seed an active workspace with self already as member — idempotent
    // poll re-tick shouldn't duplicate-INSERT.
    let selfPub = try selfPubkeyHex()
    try db.writeSQL { raw in
      try raw.execute(
        sql: """
          INSERT INTO \(Schema.Workspaces.tableName)
              (\(Schema.Workspaces.id), \(Schema.Workspaces.name),
               \(Schema.Workspaces.createdAtMs), \(Schema.Workspaces.createdByMemberID))
          VALUES (?, 'TestRoom', 1700000000000, ?)
          """, arguments: [workspaceID, adminMemberID])
      try raw.execute(
        sql: """
          INSERT INTO \(Schema.TeamMembers.tableName)
              (\(Schema.TeamMembers.id), \(Schema.TeamMembers.workspaceID),
               \(Schema.TeamMembers.role), \(Schema.TeamMembers.pubkeyHex),
               \(Schema.TeamMembers.displayName), \(Schema.TeamMembers.addedAtMs))
          VALUES ('self-existing', ?, 'member', ?, 'Eve', 1700000000000)
          """, arguments: [workspaceID, selfPub])
    }

    let codec = RecordingDecoderCodec()
    codec.stubPlaintext = makePlaintext()
    let request = try makeRequest()

    do {
      _ = try await makeService(codec: codec).acceptApproved(request: request)
      XCTFail("expected .inviteAlreadyAccepted")
    } catch LeafError.inviteAlreadyAccepted {
      // pass
    }

    // Defence: no duplicate INSERT — exactly one member row still.
    let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: false)
    XCTAssertEqual(members.count, 1, "already-current path must not duplicate-INSERT")
  }
}

// MARK: - Recording crypto stubs

private final class AcceptApprovedKDFStub: InviteKDF, @unchecked Sendable {
  var stubKey = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
  var calls: [(sharedSecret: SharedSecret, otp: String)] = []
  func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
    calls.append((sharedSecret, otp))
    return stubKey
  }
  func hashOTPForServerStorage(otp: String) -> Data { Data(repeating: 0xEF, count: 32) }
}

private final class RecordingDecoderCodec: InviteBlobCodec, @unchecked Sendable {
  /// Plaintext returned by `decode(_:)`. Tests override per assertion.
  var stubPlaintext: InvitePlaintext = InvitePlaintext(
    teamKeyBase64: Data(repeating: 0x00, count: 32).base64EncodedString(),
    teamKeyID: "00000000-0000-0000-0000-000000000000",
    orgID: "00000000-0000-0000-0000-000000000000",
    orgName: "Stub",
    adminMemberID: "stub",
    adminDisplayName: "Stub Admin",
    issuedAtMs: 0
  )
  var decodeCalls: [(blob: InviteBlob, wrapKey: SymmetricKey)] = []
  func encode(_ plaintext: InvitePlaintext, adminPubkey: Data, wrapKey: SymmetricKey) throws
    -> InviteBlob
  {
    fatalError("acceptApproved path doesn't encode")
  }
  func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
    decodeCalls.append((blob, wrapKey))
    return stubPlaintext
  }
}
