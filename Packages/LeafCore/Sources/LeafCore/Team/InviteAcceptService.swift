//
//  InviteAcceptService.swift
//  LeafCore
//
//  Phase 5.2.E — invitee-side orchestrator. Two-step flow:
//
//   1. fetchInvite(token:) → one-shot relay GET (KV consumes), returns blob bytes
//      caller'у (Reader держит в RAM пока юзер вводит OTP).
//   2. acceptInvite(blob:, otp:, displayName:) → ECDH(invitee_priv, admin_pub) +
//      KDF(otp) + AES-GCM decode → materializes 1 row org + 2 rows team_members
//      (admin from blob + self with new UUID + invitee displayName + invitee
//      pubkey hex) + 1 row team_keys + writes teamKey file via TeamKeystore.
//
//  Atomicity: keystore-first (orphan file < orphan DB rows), затем DB writes
//  в одной транзакции. Mirror OrgService.createPersonalOrg ordering (5.1.D).
//
//  Inject'абельные factories `now` / `identity` / `generateMemberID` —
//  deterministic test E2E round-trip mirror InviteService (5.2.D).
//

import CryptoKit
import Foundation

public struct InviteAcceptService: Sendable {
    private let database: Database
    private let relayClient: RelayClient
    private let inviteKDF: any InviteKDF
    private let inviteBlobCodec: any InviteBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey
    private let generateMemberID: @Sendable () -> String

    public init(
        database: Database,
        relayClient: RelayClient,
        inviteKDF: any InviteKDF,
        inviteBlobCodec: any InviteBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil,
        generateMemberID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.database = database
        self.relayClient = relayClient
        self.inviteKDF = inviteKDF
        self.inviteBlobCodec = inviteBlobCodec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
        self.generateMemberID = generateMemberID
    }

    /// One-shot relay fetch — KV consumes invite at this call.
    /// Caller (Reader) holds returned blob in RAM across OTP retries.
    public func fetchInvite(token: String) async throws -> InviteBlob {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LeafError.invalidPayload
        }
        let fetched = try await relayClient.getInvite(token: trimmed)
        return InviteBlob(bytes: fetched.blob)
    }

    /// Phase 5.5.B — invitee receives single deep-link `leaf://invite/<token>#<otp>`. Parse +
    /// fetch + return blob alongside OTP так, чтобы caller (Reader) auto-prefilled OTP в UI.
    /// `inviteNotFound` от relay re-maps в `.inviteAlreadyConsumed` (per 5.5.B UX — explicit "уже консумлено / истекло"
    /// message vs old "not found" generic).
    public func fetchInvite(inviteURL url: URL) async throws -> (blob: InviteBlob, otp: String) {
        let token: String
        let otp: String
        switch InviteURL.parse(url) {
        case .success(let parsed):
            token = parsed.token
            otp = parsed.otp
        case .failure:
            throw LeafError.inviteURLMalformed
        }
        do {
            let blob = try await fetchInvite(token: token)
            return (blob: blob, otp: otp)
        } catch LeafError.inviteNotFound {
            throw LeafError.inviteAlreadyConsumed
        }
    }

    /// Decrypts blob with derived wrapKey (ECDH(invitee_priv, admin_pub_from_header) +
    /// KDF(otp)) → materializes org/team_members/team_keys + writes teamKey file.
    /// Throws inviteAlreadyAccepted / inviteOTPInvalid / inviteBlobMalformed.
    public func acceptInvite(
        blob: InviteBlob,
        otp: String,
        displayName: String
    ) async throws -> AcceptedInvite {
        // 1. Preflight — non-empty displayName. Track-5 S2: the single-workspace
        // invariant is gone; rejoin / membership-conflict checks happen in
        // step 11 once we know the target workspaceID from the decoded blob.
        let trimmedDN = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDN.isEmpty else {
            throw LeafError.invalidPayload
        }

        // 2. Identity (idempotent X25519 priv).
        let priv = try identity()

        // 3. Peek admin pubkey from blob header.
        let header = try InviteBlobHeader.peek(from: blob)
        let adminPubHex = header.adminPubkey.map { String(format: "%02x", $0) }.joined()

        // 4. ECDH (symmetric — same shared secret as admin computed).
        let shared = try KeyAgreement.sharedSecret(privateKey: priv,
                                                   peerPublicKeyHex: adminPubHex)

        // 5. Derive wrap key with OTP salt.
        let wrapKey = try inviteKDF.deriveWrapKey(sharedSecret: shared, otp: otp)

        // 6. Decode blob. Прод-кодек conflates AES-GCM tag fail / JSON parse /
        //    short-cipher с одним `.inviteBlobMalformed` (moat — generic error,
        //    no info-string leak per decomposition §8). Здесь мы wrap'ом
        //    re-classify пост-peek decode failure как `.inviteOTPInvalid` —
        //    invitee видит retry-able "OTP doesn't match" UX. Header peek (выше)
        //    сохраняет .inviteBlobMalformed для structural failures (truncated
        //    bytes / wrong version) — non-recoverable.
        let plaintext: InvitePlaintext
        do {
            plaintext = try inviteBlobCodec.decode(blob, wrapKey: wrapKey)
        } catch LeafError.inviteOTPInvalid {
            throw LeafError.inviteOTPInvalid
        } catch LeafError.inviteBlobMalformed {
            throw LeafError.inviteOTPInvalid
        }

        // 7. Decode teamKey base64 (32B AES-256 key bytes).
        guard let teamKeyBytes = Data(base64Encoded: plaintext.teamKeyBase64),
              teamKeyBytes.count == 32 else {
            throw LeafError.inviteBlobMalformed
        }

        // 8. Self pubkey hex (lowercase).
        let selfPubHex = priv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()

        // 9. Build domain rows. `plaintext.orgID` carries the workspace id
        //    semantically (renamed at DB level by M019; JSON key unchanged for
        //    back-compat with in-flight v2 blobs).
        let workspaceID = plaintext.orgID
        let acceptedAt = now()
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(plaintext.issuedAtMs) / 1000)
        let org = Workspace(id: workspaceID,
                            name: plaintext.orgName,
                            createdAt: issuedAt,
                            createdByMemberID: plaintext.adminMemberID)
        let adminMember = TeamMember(id: plaintext.adminMemberID,
                                     workspaceID: workspaceID,
                                     role: .admin,
                                     pubkeyHex: adminPubHex,
                                     displayName: plaintext.adminDisplayName,
                                     addedAt: issuedAt,
                                     removedAt: nil)
        let selfMemberID = generateMemberID()
        let selfMember = TeamMember(id: selfMemberID,
                                    workspaceID: workspaceID,
                                    role: .member,
                                    pubkeyHex: selfPubHex,
                                    displayName: trimmedDN,
                                    addedAt: acceptedAt,
                                    removedAt: nil)
        let teamKey = TeamKey(id: plaintext.teamKeyID,
                              workspaceID: workspaceID,
                              generatedAt: issuedAt,
                              deprecatedAt: nil,
                              generatedByMemberID: plaintext.adminMemberID)

        // 10. Keystore-first (orphan file < orphan DB rows). Track-5 S2:
        //     workspace-scoped path; `writeAtomic` overwrites if a stale file
        //     remains from a prior accept attempt or rejoin path.
        try TeamKeystore.writeTeamKey(teamKeyBytes,
                                      workspaceID: workspaceID,
                                      keyID: plaintext.teamKeyID,
                                      at: keystoreRoot)

        // 11. DB writes. Three paths:
        //   - rejoin: workspace exists locally with `leftAt != nil` → clear
        //     `left_at_ms`, insert *new* self member, keep prior admin row +
        //     team_key via idempotent insertTeamKeyIfAbsent.
        //   - already-current member: workspace exists with `leftAt == nil` →
        //     refuse with `inviteAlreadyAccepted` (no double-accept).
        //   - fresh: workspace not present locally → full insert sequence
        //     (mirror OrgService.createPersonalOrg ordering).
        if let existing = try database.readWorkspace(id: workspaceID) {
            guard existing.leftAt != nil else {
                throw LeafError.inviteAlreadyAccepted
            }
            try database.clearWorkspaceLeftAt(workspaceID: workspaceID)
            try database.insertTeamMember(selfMember)
            try database.insertTeamKeyIfAbsent(teamKey)
        } else {
            try database.upsertWorkspace(org)
            try database.insertTeamMember(adminMember)
            try database.insertTeamMember(selfMember)
            try database.insertTeamKey(teamKey)
        }

        return AcceptedInvite(orgID: workspaceID,
                              orgName: plaintext.orgName,
                              teamKeyID: plaintext.teamKeyID,
                              selfMemberID: selfMemberID)
    }
}

public struct AcceptedInvite: Sendable, Hashable {
    public let orgID: String
    public let orgName: String
    public let teamKeyID: String
    public let selfMemberID: String

    public init(orgID: String, orgName: String, teamKeyID: String, selfMemberID: String) {
        self.orgID = orgID
        self.orgName = orgName
        self.teamKeyID = teamKeyID
        self.selfMemberID = selfMemberID
    }
}
