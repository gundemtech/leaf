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
//  Decoding the blob at invitee's side is handled by InviteAcceptService
//  (existing S3 code path — no changes needed).
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

    public init(
        database: Database,
        supabase: SupabaseClient,
        inviteKDF: any InviteKDF,
        inviteBlobCodec: any InviteBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    ) {
        self.database = database
        self.supabase = supabase
        self.inviteKDF = inviteKDF
        self.inviteBlobCodec = inviteBlobCodec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
    }

    // MARK: - Invitee path

    /// Submit a fresh pending join_request via the create_join_request Edge
    /// Function. Returns the inserted row (status=.pending). Throws on token
    /// invalidity (410 Gone surfaces as SupabaseError.gone — see fromStatus).
    public func submit(
        workspaceID: String,
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
              inviteePubkeyHex.allSatisfy({ $0.isHexDigit }) else {
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
}
