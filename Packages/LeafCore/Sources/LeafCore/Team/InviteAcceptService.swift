//
//  InviteAcceptService.swift
//  LeafCore
//
//  Track 5 / S3 — invitee-side orchestrator. Single-call acceptInvite(url:displayName:otp:)
//  wrapping Supabase resolve + ECDH+HKDF+AES-GCM decrypt + local workspace
//  materialization (S2 rejoin path) + best-effort workspace_members remote sync
//  with bounded retry.
//

import CryptoKit
import Foundation

public struct InviteAcceptService: Sendable {
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

    // MARK: - Preview (no network)

    public static func preview(url: URL) -> Result<URLPreview, InviteURLError> {
        switch InviteURL.parse(url) {
        case .success(let p):
            return .success(URLPreview(
                workspaceName: p.workspaceName,
                adminPubkeyHex: p.adminPubkeyHex,
                token: p.token,
                hasFragmentOTP: p.otp != nil
            ))
        case .failure(let err):
            return .failure(err)
        }
    }

    // MARK: - Accept (single-call)

    /// Parse URL → resolve via Supabase Edge Function (atomic claim) → derive wrap key →
    /// decrypt blob → materialize local workspace + members + teamKey → best-effort
    /// remote workspace_members INSERT with bounded retry.
    public func acceptInvite(url: URL,
                             displayName: String,
                             otp: String?) async throws -> AcceptedInvite {
        // 1. Validate displayName
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw LeafError.invalidPayload }

        // 2. Parse URL
        let parsed: InviteURL.Parsed
        switch InviteURL.parse(url) {
        case .success(let p): parsed = p
        case .failure: throw LeafError.inviteURLMalformed
        }

        // 3. Decode token base64url → UUID → string
        guard let tokenUUID = UUID(base64URLString: parsed.token) else {
            throw LeafError.inviteURLMalformed
        }
        let tokenString = tokenUUID.uuidString.lowercased()

        // 4. Identity
        let priv = try identity()
        let inviteePubkeyHex = priv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()

        // 5. Bootstrap Supabase auth (lazy)
        _ = try await supabase.ensureAuthenticated()

        // 6. Atomic claim via Edge Function
        let resolved: ResolvedInvite
        do {
            resolved = try await supabase.resolveInvite(token: tokenString,
                                                        inviteePubkeyHex: inviteePubkeyHex)
        } catch SupabaseError.inviteNotResolvable {
            throw LeafError.inviteAlreadyConsumed
        }

        // 7. OTP gating
        let effectiveOTP: String
        if resolved.requireOTP {
            guard let candidate = otp ?? parsed.otp, !candidate.isEmpty else {
                throw LeafError.inviteOTPRequired
            }
            effectiveOTP = candidate
        } else {
            effectiveOTP = ""
        }

        // 8. ECDH + HKDF + decrypt
        let shared = try KeyAgreement.sharedSecret(privateKey: priv,
                                                   peerPublicKeyHex: resolved.adminPubkey)
        let wrapKey = try inviteKDF.deriveWrapKey(sharedSecret: shared, otp: effectiveOTP)
        let blob = InviteBlob(bytes: resolved.encryptedTeamkey)
        let plaintext: InvitePlaintext
        do {
            plaintext = try inviteBlobCodec.decode(blob, wrapKey: wrapKey)
        } catch LeafError.inviteOTPInvalid {
            throw LeafError.inviteOTPInvalid
        } catch LeafError.inviteBlobMalformed {
            throw LeafError.inviteOTPInvalid
        }

        // 9. Defense-in-depth: blob's workspace id must match resolve response
        guard plaintext.orgID == resolved.workspaceID else {
            throw LeafError.inviteBlobMalformed
        }

        // 10. teamKey bytes
        guard let teamKeyBytes = Data(base64Encoded: plaintext.teamKeyBase64),
              teamKeyBytes.count == 32 else {
            throw LeafError.inviteBlobMalformed
        }

        // 11. Build value types
        let acceptedAt = now()
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(plaintext.issuedAtMs) / 1000)
        let workspaceID = resolved.workspaceID
        let workspaceName = resolved.workspaceName

        let workspaceRow = Workspace(id: workspaceID,
                                     name: workspaceName,
                                     createdAt: issuedAt,
                                     createdByMemberID: plaintext.adminMemberID)
        let adminMember = TeamMember(id: plaintext.adminMemberID,
                                     workspaceID: workspaceID,
                                     role: .admin,
                                     pubkeyHex: resolved.adminPubkey,
                                     displayName: plaintext.adminDisplayName,
                                     addedAt: issuedAt,
                                     removedAt: nil)
        let selfMemberID = generateMemberID()
        let selfMember = TeamMember(id: selfMemberID,
                                    workspaceID: workspaceID,
                                    role: .member,
                                    pubkeyHex: inviteePubkeyHex,
                                    displayName: trimmedName,
                                    addedAt: acceptedAt,
                                    removedAt: nil)
        let teamKey = TeamKey(id: plaintext.teamKeyID,
                              workspaceID: workspaceID,
                              generatedAt: issuedAt,
                              deprecatedAt: nil,
                              generatedByMemberID: plaintext.adminMemberID)

        // 12. Keystore-first (S2 substrate — orphan file better than orphan DB rows)
        try TeamKeystore.writeTeamKey(teamKeyBytes,
                                      workspaceID: workspaceID,
                                      keyID: plaintext.teamKeyID,
                                      at: keystoreRoot)

        // 13. DB writes (three-path: fresh / rejoin / already-current)
        if let existing = try database.readWorkspace(id: workspaceID) {
            guard existing.leftAt != nil else {
                throw LeafError.inviteAlreadyAccepted
            }
            try database.clearWorkspaceLeftAt(workspaceID: workspaceID)
            try database.insertTeamMember(selfMember)
            try database.insertTeamKeyIfAbsent(teamKey)
        } else {
            try database.upsertWorkspace(workspaceRow)
            try database.insertTeamMember(adminMember)
            try database.insertTeamMember(selfMember)
            try database.insertTeamKey(teamKey)
        }

        // 14. Best-effort workspace_members remote sync with bounded retry (in-process).
        // Failures do NOT roll back local state (invitee can use Team locally; admin's
        // pill-row catches up when sync succeeds or on next retry).
        let syncStatus = await retryInsertWorkspaceMember(
            workspaceID: workspaceID,
            pubkeyHex: inviteePubkeyHex,
            displayName: trimmedName
        )

        return AcceptedInvite(
            orgID: workspaceID,
            orgName: workspaceName,
            teamKeyID: plaintext.teamKeyID,
            selfMemberID: selfMemberID,
            membershipSyncStatus: syncStatus
        )
    }

    /// Retries supabase.insertWorkspaceMember up to 3 times with exponential backoff.
    /// On `.conflict` (idempotent), returns `.ok`. On final failure, returns `.pending(LeafError.unknown)`.
    private func retryInsertWorkspaceMember(workspaceID: String,
                                            pubkeyHex: String,
                                            displayName: String) async -> MembershipSyncStatus {
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
                if case .conflict = err { return .ok }  // already inserted; idempotent OK
                lastReason = String(describing: err)
            } catch {
                lastReason = String(describing: error)
            }
        }
        return .pending(reason: lastReason)
    }
}

// MARK: - URLPreview (no-network preview from URL params)

public struct URLPreview: Sendable, Equatable {
    public let workspaceName: String
    public let adminPubkeyHex: String
    public let token: String
    public let hasFragmentOTP: Bool
}

// MARK: - AcceptedInvite (extended with membership sync status)

public struct AcceptedInvite: Sendable, Hashable {
    public let orgID: String
    public let orgName: String
    public let teamKeyID: String
    public let selfMemberID: String
    public let membershipSyncStatus: MembershipSyncStatus

    public init(orgID: String, orgName: String, teamKeyID: String,
                selfMemberID: String, membershipSyncStatus: MembershipSyncStatus) {
        self.orgID = orgID
        self.orgName = orgName
        self.teamKeyID = teamKeyID
        self.selfMemberID = selfMemberID
        self.membershipSyncStatus = membershipSyncStatus
    }
}

public enum MembershipSyncStatus: Sendable, Hashable {
    case ok
    /// Reason string carried for diagnostic logging (e.g., "transport: timeout").
    /// UI doesn't surface this; just shows a generic "Sync pending — retry?" affordance.
    case pending(reason: String)
}
