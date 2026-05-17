//
//  InviteService.swift
//  LeafCore
//
//  Phase 5.2.D — admin-side orchestrator. Reads org/admin-member/active-teamKey
//  + X25519 priv from keystore → builds InvitePlaintext → ECDH + KDF + AES-GCM
//  via injected InviteKDF + InviteBlobCodec → POST to RelayClient → returns
//  InviteOutbound (token+OTP for OOB to invitee).
//
//  Inject'абельные factories `now` / `randomOTP` / `identity` — deterministic
//  test round-trip. Default identity = IdentityService.ensureLocalIdentity (idempotent).
//

import CryptoKit
import Foundation
import Security

public struct InviteService: Sendable {
    private let database: Database
    private let relayClient: RelayClient
    private let inviteKDF: any InviteKDF
    private let inviteBlobCodec: any InviteBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let randomOTP: @Sendable () throws -> String
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey

    public init(
        database: Database,
        relayClient: RelayClient,
        inviteKDF: any InviteKDF,
        inviteBlobCodec: any InviteBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomOTP: @escaping @Sendable () throws -> String = Self.secureRandomOTP,
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    ) {
        self.database = database
        self.relayClient = relayClient
        self.inviteKDF = inviteKDF
        self.inviteBlobCodec = inviteBlobCodec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.randomOTP = randomOTP
        self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
    }

    /// Admin-side: build invite blob, POST to relay, return token+OTP for OOB transmission.
    public func generateInvite(inviteePubkeyHex: String) async throws -> InviteOutbound {
        // 1. Validate hex (64 chars, [0-9a-fA-F]).
        guard inviteePubkeyHex.count == 64,
            inviteePubkeyHex.allSatisfy({ $0.isHexDigit })
        else {
            throw LeafError.invalidPayload
        }
        let lowercased = inviteePubkeyHex.lowercased()

        // 2-4. Read DB rows.
        guard let org = try database.readOrg() else {
            throw LeafError.databaseUnavailable
        }
        let members = try database.readTeamMembers(orgID: org.id, includeRemoved: false)
        guard let selfMember = members.first else {
            throw LeafError.databaseUnavailable
        }
        guard let activeKey = try database.readActiveTeamKey() else {
            throw LeafError.databaseUnavailable
        }
        let teamKeyBytes = try TeamKeystore.readTeamKey(id: activeKey.id, at: keystoreRoot)

        // 5. Identity (X25519 priv).
        let priv = try identity()

        // 6. OTP.
        let otp = try randomOTP()

        // 7. ECDH.
        let shared = try KeyAgreement.sharedSecret(
            privateKey: priv,
            peerPublicKeyHex: lowercased)

        // 8. Wrap key.
        let wrapKey = try inviteKDF.deriveWrapKey(sharedSecret: shared, otp: otp)

        // 9. Plaintext.
        let nowMs = Int64(now().timeIntervalSince1970 * 1000)
        let plaintext = InvitePlaintext(
            teamKeyBase64: teamKeyBytes.base64EncodedString(),
            teamKeyID: activeKey.id,
            orgID: org.id,
            orgName: org.name,
            adminMemberID: selfMember.id,
            adminDisplayName: selfMember.displayName,
            issuedAtMs: nowMs
        )

        // 10. Encode blob.
        let blob = try inviteBlobCodec.encode(
            plaintext,
            adminPubkey: priv.publicKey.rawRepresentation,
            wrapKey: wrapKey)

        // 11. Expiry = now + 24h.
        let expiresAtMs = nowMs + 24 * 60 * 60 * 1000

        // 12. POST to relay.
        let token = try await relayClient.postInvite(
            memberPubkeyHex: lowercased,
            blob: blob.bytes,
            expiresAtMs: expiresAtMs
        )

        return InviteOutbound(
            token: token.value,
            otp: otp,
            expiresAtMs: token.expiresAtMs,
            inviteePubkeyHex: lowercased)
    }

    /// Phase 5.5.B — admin pastes invitee Join code (formatted base32-Crockford OR legacy hex).
    /// Decodes to 32-byte pubkey via `JoinCode.decode`, then delegates to `generateInvite(inviteePubkeyHex:)`.
    /// Wraps `JoinCodeError` cases в LeafError для UI consumer'ов (mirror existing error model).
    public func generateInvite(inviteeJoinCode: String) async throws -> InviteOutbound {
        let pubkey: Data
        switch JoinCode.decode(inviteeJoinCode) {
        case .success(let bytes):
            pubkey = bytes
        case .failure(.malformed):
            throw LeafError.joinCodeMalformed
        case .failure(.checksumMismatch):
            throw LeafError.joinCodeChecksumMismatch
        }
        let hex = pubkey.map { String(format: "%02x", $0) }.joined()
        return try await generateInvite(inviteePubkeyHex: hex)
    }

    /// Admin-side revoke: best-effort DELETE on relay (idempotent — relay returns 204).
    public func revokeInvite(token: String) async throws {
        try await relayClient.deleteInvite(token: token)
    }

    /// Default OTP factory: 6 ASCII digits via SecRandomCopyBytes.
    /// Modulo bias < 0.0001% (2³² mod 10⁶) — irrelevant для invite OTP threat model.
    public static func secureRandomOTP() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, 4, &bytes)
        guard status == errSecSuccess else {
            throw LeafError.keychainUnavailable(status)
        }
        let n =
            (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return String(format: "%06d", n % 1_000_000)
    }
}
