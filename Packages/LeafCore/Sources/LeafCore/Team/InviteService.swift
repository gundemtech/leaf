//
//  InviteService.swift
//  LeafCore
//
//  Track 5 / S3 — admin-side orchestrator. Reads workspace + admin member +
//  active teamKey + teamKey bytes scoped to workspaceID. Computes ECDH + HKDF
//  + AES-GCM via injected codec; POSTs encrypted_teamkey to Supabase invites
//  table via SupabaseClient (replaces Phase 5.5 Cloudflare RelayClient.postInvite).
//  Returns InviteOutbound with composed Track 5 §12 URL + optional OTP.
//

import CryptoKit
import Foundation
import Security

public struct InviteService: Sendable {
    private let database: Database
    private let supabase: SupabaseClient
    private let inviteKDF: any InviteKDF
    private let inviteBlobCodec: any InviteBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let randomOTP: @Sendable () throws -> String
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey

    public init(
        database: Database,
        supabase: SupabaseClient,
        inviteKDF: any InviteKDF,
        inviteBlobCodec: any InviteBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomOTP: @escaping @Sendable () throws -> String = InviteService.secureRandomOTP,
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    ) {
        self.database = database
        self.supabase = supabase
        self.inviteKDF = inviteKDF
        self.inviteBlobCodec = inviteBlobCodec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.randomOTP = randomOTP
        self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
    }

    /// Admin-side: build invite blob, POST to Supabase invites table, return URL + optional OTP.
    /// OTP only generated and emitted when `requireOTP=true`. Default OFF — magic link itself
    /// carries 122-bit token entropy; OTP is opt-in second factor.
    public func generateInvite(workspaceID: String,
                               inviteePubkeyHex: String,
                               requireOTP: Bool = false) async throws -> InviteOutbound {
        // 1. Validate hex
        guard inviteePubkeyHex.count == 64,
              inviteePubkeyHex.allSatisfy({ $0.isHexDigit }) else {
            throw LeafError.invalidPayload
        }
        let inviteeHex = inviteePubkeyHex.lowercased()

        // 2-4. Read workspace state scoped to workspaceID
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

        // 5. Identity
        let priv = try identity()

        // 6. OTP — only when requireOTP=true; KDF salt="" otherwise (per D6: ECDH provides primary 256-bit security)
        let otp: String? = requireOTP ? try randomOTP() : nil
        let kdfOTP: String = otp ?? ""

        // 7. ECDH
        let shared = try KeyAgreement.sharedSecret(privateKey: priv, peerPublicKeyHex: inviteeHex)

        // 8. Wrap key
        let wrapKey = try inviteKDF.deriveWrapKey(sharedSecret: shared, otp: kdfOTP)

        // 9. Plaintext + blob
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
            plaintext, adminPubkey: priv.publicKey.rawRepresentation, wrapKey: wrapKey
        )

        // 10. OTP hash (only when requireOTP) — delegated to InviteKDF (moat: salt label lives in ProdInviteKDF / LeafCorePrivate).
        let otpHashBase64: String? = otp.map { otpVal in
            inviteKDF.hashOTPForServerStorage(otp: otpVal).base64EncodedString()
        }

        // 11. POST to Supabase
        let expiresAtMs = nowMs + 24 * 60 * 60 * 1000
        let adminHex = priv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
        let issued = try await supabase.postInvite(
            workspaceID: workspace.id,
            adminPubkeyHex: adminHex,
            encryptedTeamkey: blob.bytes,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAtMs) / 1000),
            requireOTP: requireOTP,
            otpHashBase64: otpHashBase64
        )

        // 12. Compose Track 5 §12 URL
        let composed = InviteURL.compose(
            token: issued.tokenBase64URL,
            workspaceName: workspace.name,
            adminPubkeyHex: adminHex,
            otp: otp
        )

        return InviteOutbound(
            token: issued.tokenBase64URL,
            url: composed.url,
            otp: otp,
            expiresAtMs: expiresAtMs,
            inviteePubkeyHex: inviteeHex
        )
    }

    /// Admin pastes invitee Join code; decode → hex → delegate.
    public func generateInvite(workspaceID: String,
                               inviteeJoinCode: String,
                               requireOTP: Bool = false) async throws -> InviteOutbound {
        let pubkey: Data
        switch JoinCode.decode(inviteeJoinCode) {
        case .success(let bytes): pubkey = bytes
        case .failure(.malformed): throw LeafError.joinCodeMalformed
        case .failure(.checksumMismatch): throw LeafError.joinCodeChecksumMismatch
        }
        let hex = pubkey.map { String(format: "%02x", $0) }.joined()
        return try await generateInvite(
            workspaceID: workspaceID, inviteePubkeyHex: hex, requireOTP: requireOTP
        )
    }

    /// Admin-side revoke — best-effort stub. S3 ships no-op (invite auto-expires in 24h).
    /// S4 carry-over: PATCH /rest/v1/invites?token=eq.<uuid> SET expires_at=now().
    public func revokeInvite(token: String) async throws {
        // TODO(S4): PATCH invites SET expires_at = now() via SupabaseClient
    }

    public static func secureRandomOTP() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, 4, &bytes)
        guard status == errSecSuccess else {
            throw LeafError.keychainUnavailable(status)
        }
        let n = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
              | (UInt32(bytes[2]) << 8)  |  UInt32(bytes[3])
        return String(format: "%06d", n % 1_000_000)
    }
}

// InviteOutbound value type defined in InviteOutbound.swift
