//
//  JoinRequestService.swift
//  LeafCore
//
//  M027 invite-redesign — submit (invitee) + approve / decline (admin) +
//  cancel (invitee) + listPending / fetchOwn. At admin's approve moment,
//  performs local ECDH + InviteKDF + InviteBlobCodec seal using the S3
//  envelope v=1 (reused as-is). Then PATCHes join_requests row via the
//  approve_join_request Edge Function with the sealed blob.
//
//  Invitee post-approval materialisation lives here too (`acceptApproved`)
//  — symmetric counterpart to `approve` that decodes the admin-sealed blob
//  and writes the local workspace + team_members + team_keys rows. The
//  discipline mirrors `InviteAcceptService.acceptInvite` from S3 (same
//  envelope, same three-path fresh/rejoin/already-current materialisation,
//  same best-effort `workspace_members` remote sync); the only differences
//  are no URL parse + no OTP (closed-mode invites carry no out-of-band
//  secret — RLS + AES-GCM tag are the trust gates).
//

import CryptoKit
import Foundation

public struct JoinRequestService: Sendable {
  private let database: Database
  private let supabase: SupabaseClient
  private let inviteKDF: any InviteKDF
  private let inviteBlobCodec: any InviteBlobCodec
  private let keystoreRoot: URL
  private let now: @Sendable () -> Date
  private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey
  private let generateMemberID: @Sendable () -> String

  public init(
    database: Database,
    supabase: SupabaseClient,
    inviteKDF: any InviteKDF,
    inviteBlobCodec: any InviteBlobCodec,
    keystoreRoot: URL = TeamKeystore.defaultRoot(),
    now: @escaping @Sendable () -> Date = { Date() },
    identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil,
    generateMemberID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.database = database
    self.supabase = supabase
    self.inviteKDF = inviteKDF
    self.inviteBlobCodec = inviteBlobCodec
    self.keystoreRoot = keystoreRoot
    self.now = now
    self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
    self.generateMemberID = generateMemberID
  }

  // MARK: - Invitee path

  /// Submit a fresh pending join_request via the create_join_request Edge
  /// Function. Returns the inserted row (status=.pending). Throws on token
  /// invalidity (410 Gone surfaces as SupabaseError.gone — see fromStatus).
  public func submit(
    workspaceID: String? = nil,
    code: String,
    displayName: String
  ) async throws -> JoinRequest {
    try await supabase.invokeCreateJoinRequest(
      workspaceID: workspaceID, code: code, displayName: displayName
    )
  }

  /// Invitee self-cancel own pending request. Idempotent on 403 (RLS USING
  /// clause filters non-pending rows out → service throws SupabaseError).
  public func cancel(requestID: String) async throws {
    try await supabase.invokeCancelJoinRequest(requestID: requestID)
  }

  /// Invitee polls own request (for the waiting card state machine: pending /
  /// approved / declined / cancelled / expired).
  public func fetchOwn(requestID: String) async throws -> JoinRequest? {
    try await supabase.fetchOwnJoinRequest(requestID: requestID)
  }

  // MARK: - Admin path

  /// Admin's queue — pending requests for the workspace (RLS gates by admin
  /// scope). Sorted newest first.
  public func listPending(workspaceID: String) async throws -> [JoinRequest] {
    try await supabase.listPendingJoinRequests(workspaceID: workspaceID)
  }

  /// Admin approves a pending request. Performs the S3 envelope v=1 seal
  /// locally (admin priv + invitee pub → ECDH → HKDF → AES-GCM), then PATCHes
  /// join_requests via the approve_join_request Edge Function with the
  /// sealed blob. The Edge Function:
  ///   1. UPDATE join_requests (RLS admin_decide gates)
  ///   2. Atomically increment invite_tokens.used_count via service-role RPC
  ///   3. Best-effort APNs push to invitee (kind=invite_request_approved)
  public func approve(
    workspaceID: String,
    requestID: String,
    inviteePubkeyHex: String
  ) async throws {
    // Validate hex shape upfront (Edge Function also validates, but we
    // want to fail fast before doing local ECDH work).
    guard inviteePubkeyHex.count == 64,
      inviteePubkeyHex.allSatisfy({ $0.isHexDigit })
    else {
      throw LeafError.invalidPayload
    }

    // Read workspace state.
    guard let workspace = try database.readWorkspace(id: workspaceID) else {
      throw LeafError.databaseUnavailable
    }
    let members = try database.readTeamMembers(workspaceID: workspace.id, includeRemoved: false)
    guard let selfMember = members.first else { throw LeafError.databaseUnavailable }
    guard let activeKey = try database.readActiveTeamKey(workspaceID: workspace.id) else {
      throw LeafError.databaseUnavailable
    }
    let teamKeyBytes = try TeamKeystore.readTeamKey(
      workspaceID: workspace.id, keyID: activeKey.id, at: keystoreRoot
    )

    // ECDH(admin_priv, invitee_pub) → HKDF (otp="" — closed-mode invites
    // don't carry an OTP; AES-GCM tag provides primary security per S3).
    let adminPriv = try identity()
    let shared = try KeyAgreement.sharedSecret(
      privateKey: adminPriv, peerPublicKeyHex: inviteePubkeyHex.lowercased()
    )
    let wrapKey = try inviteKDF.deriveWrapKey(sharedSecret: shared, otp: "")

    // Build plaintext + seal.
    let nowMs = Int64(now().timeIntervalSince1970 * 1000)
    let plaintext = InvitePlaintext(
      teamKeyBase64: teamKeyBytes.base64EncodedString(),
      teamKeyID: activeKey.id,
      orgID: workspace.id,
      orgName: workspace.name,
      adminMemberID: selfMember.id,
      adminDisplayName: selfMember.displayName,
      issuedAtMs: nowMs
    )
    let blob = try inviteBlobCodec.encode(
      plaintext, adminPubkey: adminPriv.publicKey.rawRepresentation, wrapKey: wrapKey
    )

    // POST to approve_join_request Edge Function. The Edge Function
    // performs the PATCH + RPC + best-effort apns_push.
    try await supabase.invokeApproveJoinRequest(
      requestID: requestID, encryptedTeamKey: blob.bytes
    )
  }

  /// Admin declines a pending request. NO push to invitee per spec §6
  /// (decline is silent — invitee learns via in-app Realtime/poll).
  public func decline(requestID: String) async throws {
    try await supabase.invokeDeclineJoinRequest(requestID: requestID)
  }

  /// Admin soft-deletes an invite token. Existing pending requests against
  /// this token remain in the queue; future clicks fail at create_join_request
  /// pre-flight (410 Gone).
  public func deleteInviteToken(code: String) async throws {
    try await supabase.invokeDeleteInviteToken(code: code)
  }

  // MARK: - Invitee post-approval materialisation

  /// Invitee-side counterpart to `approve`. Consumes a `JoinRequest` row
  /// with `status == .approved` (so `encryptedTeamKey` + `decidedByPubkeyHex`
  /// are non-nil per the M027 server CHECK), runs ECDH(invitee_priv,
  /// admin_pub) + HKDF(salt="") + AES-GCM decrypt over the S3 envelope v=1
  /// blob, then materialises the workspace + admin/self team_members + the
  /// active teamKey locally. Mirrors `InviteAcceptService.acceptInvite`
  /// steps 8-14 (decode, value-type build, keystore-first write, three-
  /// path DB writes, best-effort remote member sync).
  ///
  /// **Total + idempotent + self-healing.** The local write (step 9) goes
  /// through `Database.materializeJoinedWorkspace` — one transaction that
  /// converges to {workspace + admin + self + key} regardless of prior local
  /// state (fresh / half-materialised orphan / previously-left / deleted) and
  /// never duplicates by pubkey. So the JoinRequestsReader poll loop can call
  /// this on every `.approved` tick (and across relaunches) without churn, and
  /// a prior partial attempt self-heals on the next run. No longer throws
  /// `inviteAlreadyAccepted`.
  public func acceptApproved(request: JoinRequest) async throws -> AcceptedInvite {
    // 1. Pre-conditions — server-side CHECK constraint already enforces
    // approved ⇒ encryptedTeamKey non-null (migration §92), but defensive
    // here so a tampered relay can't trick us into running ECDH against
    // an unsealed row.
    guard request.status == .approved else { throw LeafError.invalidPayload }
    guard let encryptedBlob = request.encryptedTeamKey else { throw LeafError.invalidPayload }
    guard let adminPubkeyHex = request.decidedByPubkeyHex else { throw LeafError.invalidPayload }
    guard adminPubkeyHex.count == 64,
      adminPubkeyHex.allSatisfy({ $0.isHexDigit })
    else { throw LeafError.invalidPayload }

    // 2. Identity — confirm this row was sealed against THIS device's pubkey
    // (defence-in-depth: RLS self_read already gates server-side, but a
    // local app handed a row by some non-RLS code path would still need
    // to fail closed).
    let priv = try identity()
    let inviteePubkeyHex = priv.publicKey.rawRepresentation
      .map { String(format: "%02x", $0) }.joined()
    guard request.inviteePubkeyHex.lowercased() == inviteePubkeyHex.lowercased() else {
      throw LeafError.invalidPayload
    }

    // 3. ECDH + HKDF (closed-mode: salt is empty string — no OTP in M027;
    // AES-GCM auth tag is the integrity gate).
    let shared = try KeyAgreement.sharedSecret(
      privateKey: priv,
      peerPublicKeyHex: adminPubkeyHex.lowercased()
    )
    let wrapKey = try inviteKDF.deriveWrapKey(sharedSecret: shared, otp: "")

    // 4. Decode blob
    let blob = InviteBlob(bytes: encryptedBlob)
    let plaintext: InvitePlaintext
    do {
      plaintext = try inviteBlobCodec.decode(blob, wrapKey: wrapKey)
    } catch LeafError.inviteBlobMalformed {
      throw LeafError.inviteBlobMalformed
    }

    // 5. Defence-in-depth — blob's workspace id must agree with the row's
    guard plaintext.orgID == request.workspaceID else {
      throw LeafError.inviteBlobMalformed
    }

    // 6. teamKey bytes (32B AES-256 raw)
    guard let teamKeyBytes = Data(base64Encoded: plaintext.teamKeyBase64),
      teamKeyBytes.count == 32
    else { throw LeafError.inviteBlobMalformed }

    // 7. Build value types
    let acceptedAt = now()
    let issuedAt = Date(timeIntervalSince1970: TimeInterval(plaintext.issuedAtMs) / 1000)
    let workspaceID = request.workspaceID
    let workspaceName = plaintext.orgName

    let workspaceRow = Workspace(
      id: workspaceID,
      name: workspaceName,
      createdAt: issuedAt,
      createdByMemberID: plaintext.adminMemberID
    )
    let adminMember = TeamMember(
      id: plaintext.adminMemberID,
      workspaceID: workspaceID,
      role: .admin,
      pubkeyHex: adminPubkeyHex.lowercased(),
      displayName: plaintext.adminDisplayName,
      addedAt: issuedAt,
      removedAt: nil
    )
    let selfMemberID = generateMemberID()
    let selfMember = TeamMember(
      id: selfMemberID,
      workspaceID: workspaceID,
      role: .member,
      pubkeyHex: inviteePubkeyHex,
      displayName: request.inviteeDisplayName,
      addedAt: acceptedAt,
      removedAt: nil
    )
    let teamKey = TeamKey(
      id: plaintext.teamKeyID,
      workspaceID: workspaceID,
      generatedAt: issuedAt,
      deprecatedAt: nil,
      generatedByMemberID: plaintext.adminMemberID
    )

    // 8. Keystore-first (S2 substrate — orphan file is better than orphan
    // DB rows pointing at a missing key).
    try TeamKeystore.writeTeamKey(
      teamKeyBytes,
      workspaceID: workspaceID,
      keyID: plaintext.teamKeyID,
      at: keystoreRoot
    )

    // 9. Atomic, idempotent, self-healing DB write. One transaction converges
    // to {workspace + admin + self + key} from ANY prior local state — fresh,
    // half-materialised orphan, previously-left, or locally-deleted. Replaces
    // the old fresh/rejoin/already-current branch whose separate transactions
    // could commit a partial workspace and whose already-current early-return
    // reported success over an empty team (the two-Mac dogfood bug).
    try database.materializeJoinedWorkspace(
      workspace: workspaceRow,
      adminMember: adminMember,
      selfMember: selfMember,
      teamKey: teamKey
    )

    // 10. Best-effort `workspace_members` remote sync. Failures don't roll
    // back the local commit — the user can use the workspace immediately;
    // the admin's roster catches up when the next sync attempt succeeds.
    let syncStatus = await retryInsertWorkspaceMember(
      workspaceID: workspaceID,
      pubkeyHex: inviteePubkeyHex,
      displayName: request.inviteeDisplayName
    )

    return AcceptedInvite(
      orgID: workspaceID,
      orgName: workspaceName,
      teamKeyID: plaintext.teamKeyID,
      selfMemberID: selfMemberID,
      membershipSyncStatus: syncStatus
    )
  }

  /// Bounded-retry insert of the `workspace_members` row. Mirrors
  /// `InviteAcceptService.retryInsertWorkspaceMember` byte-for-byte —
  /// duplicated here to keep this service self-contained (S3 service
  /// remains the live owner of the URL-driven accept path).
  private func retryInsertWorkspaceMember(
    workspaceID: String,
    pubkeyHex: String,
    displayName: String
  ) async -> MembershipSyncStatus {
    let delays: [Duration] = [.zero, .milliseconds(200), .milliseconds(500), .seconds(2)]
    var lastReason = "no_attempts"
    for (idx, delay) in delays.enumerated() {
      if idx > 0 { try? await Task.sleep(for: delay) }
      do {
        try await supabase.insertWorkspaceMember(
          workspaceID: workspaceID, pubkeyHex: pubkeyHex, displayName: displayName
        )
        return .ok
      } catch let err as SupabaseError {
        if case .conflict = err { return .ok }
        lastReason = String(describing: err)
      } catch {
        lastReason = String(describing: error)
      }
    }
    return .pending(reason: lastReason)
  }
}
