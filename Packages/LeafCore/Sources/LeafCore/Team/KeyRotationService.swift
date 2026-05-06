import Foundation
import CryptoKit

/// Phase 5.3.D — admin-side orchestrator for team key rotation. Composes
/// 5.3.A DB lifecycle helpers + 5.3.B codec/KDF + 5.3.C wire layer into a
/// single atomic flow:
///
/// 1. Preflight: read org + active key + active members; reject self-removal.
/// 2. Compose: generate new teamKey + wrap N-1 `.rotation` blobs (ECDH+HKDF
///    per remaining peer) + 1 `.tombstone` blob (raw prior teamKey, no HKDF).
/// 3. Keystore-first: persist new teamKey bytes (orphan file < orphan rows).
/// 4. Atomic DB tx: `commitRotation` does insertNew+deprecatePrior+optional
///    markRemoved+insertNOutboxRows in one `pool.write`.
/// 5. POST iteration: continue-on-error per peer; failures drain on next
///    `resumePendingPosts()`.
///
/// Public API:
/// - `removeMember(memberID:)` — rotate teamKey + remove member atomically.
/// - `resumePendingPosts()` — drain unposted outbox rows on next launch.
///
/// Internal `performRotation(removingMember:)` accepts optional removingMember
/// so v1.1 proactive `rotate()` can be added without API churn.
public struct KeyRotationService: Sendable {
    private let database: Database
    private let relayClient: RelayClient
    private let rotationKDF: any RotationKDF
    private let rotationBlobCodec: any RotationBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) throws -> Data
    private let randomUUID: @Sendable () -> String
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey

    public init(
        database: Database,
        relayClient: RelayClient,
        rotationKDF: any RotationKDF,
        rotationBlobCodec: any RotationBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        randomBytes: @escaping @Sendable (Int) throws -> Data = KeyRotationService.secureRandom,
        randomUUID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    ) {
        self.database = database
        self.relayClient = relayClient
        self.rotationKDF = rotationKDF
        self.rotationBlobCodec = rotationBlobCodec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.randomBytes = randomBytes
        self.randomUUID = randomUUID
        self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
    }

    public static let secureRandom: @Sendable (Int) throws -> Data = { length in
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        guard status == errSecSuccess else { throw LeafError.invalidPayload }
        return Data(bytes)
    }

    // MARK: - Public API

    /// Removes a team member + rotates teamKey. Returns outcome with posted/pending
    /// counts. Pending POSTs (network/relay errors) drain on next
    /// `resumePendingPosts()`. Continue-on-error per peer — single peer failure
    /// does not block others.
    public func removeMember(memberID: String) async throws -> RotationOutcome {
        let prepared = try performRotation(removingMember: memberID)
        return await iterateOutboxRows(
            prepared.outboxRows,
            newKeyID: prepared.newKeyID,
            priorKeyID: prepared.priorKeyID
        )
    }

    /// Drains all unposted `rotation_outbox` rows. Called from Agent on startup
    /// (Task.detached) to retry POSTs after crash mid-iteration. Returns aggregate
    /// outcome across all rows; `newKeyID`/`priorKeyID` are empty strings because
    /// resume may drain rows from multiple historical rotation events.
    public func resumePendingPosts() async throws -> RotationOutcome {
        let unposted = try database.readUnpostedRotationOutboxRows()
        if unposted.isEmpty {
            return RotationOutcome(newKeyID: "", priorKeyID: "", postedCount: 0, pendingCount: 0, totalCount: 0)
        }
        return await iterateOutboxRows(unposted, newKeyID: "", priorKeyID: "")
    }

    /// Iterates outbox rows, POSTs each to relay, marks `posted_at_ms` on success.
    /// Continue-on-error — accumulates posted/pending counts. Used by both
    /// `removeMember` (fresh outbox) and `resumePendingPosts` (drain unposted).
    private func iterateOutboxRows(
        _ rows: [RotationOutboxRow],
        newKeyID: String,
        priorKeyID: String
    ) async -> RotationOutcome {
        var posted = 0
        var pending = 0
        for row in rows {
            do {
                _ = try await relayClient.postRotationBlob(
                    peerPubkeyHex: row.peerPubkeyHex,
                    blob: row.blob,
                    expiresAtMs: row.expiresAtMs
                )
                try database.markRotationOutboxPosted(
                    peerPubkeyHex: row.peerPubkeyHex,
                    newKeyID: row.newKeyID,
                    at: now()
                )
                posted += 1
            } catch {
                // Continue-on-error — pending POSTs drain on next resumePendingPosts().
                pending += 1
            }
        }
        return RotationOutcome(
            newKeyID: newKeyID,
            priorKeyID: priorKeyID,
            postedCount: posted,
            pendingCount: pending,
            totalCount: rows.count
        )
    }

    // MARK: - Internal

    /// Result of `performRotation` — outbox rows ready for POST iteration.
    struct PreparedRotation {
        let newKeyID: String
        let priorKeyID: String
        let outboxRows: [RotationOutboxRow]
    }

    /// Phase 1-6 of `removeMember`: preflight + compose blobs + keystore-first
    /// + atomic DB commit. Throws on any precondition violation; rollback
    /// automatic. Caller does POST iteration on returned `outboxRows`.
    func performRotation(removingMember: String?) throws -> PreparedRotation {
        // 1. Preflight — read-only checks
        guard let org = try database.readOrg() else {
            throw LeafError.invalidPayload
        }
        let selfMemberID = org.createdByMemberID

        if let removingMember, removingMember == selfMemberID {
            throw LeafError.cannotRemoveSelfFromTeam
        }

        guard let priorActiveKey = try database.readActiveTeamKey() else {
            throw LeafError.invalidPayload
        }
        let priorKeyID = priorActiveKey.id

        let activeMembers = try database.readTeamMembers(orgID: org.id, includeRemoved: false)

        var removedMember: TeamMember?
        if let removingMember {
            guard let m = activeMembers.first(where: { $0.id == removingMember }) else {
                throw LeafError.invalidPayload
            }
            removedMember = m
        }

        // 2. Read prior teamKey from keystore (for tombstone wrap)
        let priorTeamKeyBytes = try TeamKeystore.readTeamKey(id: priorKeyID, at: keystoreRoot)

        // 3. Generate new teamKey + IDs
        let newKeyID = randomUUID()
        guard let newKeyUUID = UUID(uuidString: newKeyID) else {
            throw LeafError.invalidPayload
        }
        let newKeyIDData = withUnsafeBytes(of: newKeyUUID.uuid) { Data($0) }
        let newTeamKeyBytes = try randomBytes(32)
        let nowDate = now()
        let nowMs = Int64(nowDate.timeIntervalSince1970 * 1000)
        let expiresAtMs = nowMs + 24 * 60 * 60 * 1000

        let adminPriv = try identity()

        // 4. Compose blobs in-memory
        var outboxRows: [RotationOutboxRow] = []
        for member in activeMembers {
            if member.id == selfMemberID { continue }

            if let removed = removedMember, member.id == removed.id {
                // .tombstone wrap (raw prior teamKey, no HKDF — 5.3.B AD #6).
                // KeyAgreement.decodePublicKey validates 64-char hex format.
                let removedPubkey = try KeyAgreement
                    .decodePublicKey(hex: member.pubkeyHex)
                    .rawRepresentation
                let wrapKey = SymmetricKey(data: priorTeamKeyBytes)
                let plaintext = RotationPlaintext(
                    kind: .tombstone,
                    newTeamKeyBase64: "",
                    newKeyID: priorKeyID,                          // tombstone: new == prior
                    priorKeyID: priorKeyID,
                    generatedAtMs: nowMs,
                    removedMemberID: member.id
                )
                let blob = try rotationBlobCodec.encode(
                    plaintext,
                    recipientPubkey: removedPubkey,
                    wrapKey: wrapKey
                )
                outboxRows.append(RotationOutboxRow(
                    peerPubkeyHex: member.pubkeyHex,
                    newKeyID: priorKeyID,
                    priorKeyID: priorKeyID,
                    kind: .tombstone,
                    peerMemberID: member.id,
                    blob: blob.bytes,
                    expiresAtMs: expiresAtMs,
                    createdAtMs: nowMs,
                    postedAtMs: nil
                ))
            } else {
                // .rotation wrap — ECDH(admin, peer) + HKDF. KeyAgreement helper
                // encapsulates hex validation + Curve25519 PublicKey reconstruction
                // + sharedSecret derivation (Phase 5.2.A).
                let peerPubData = try KeyAgreement
                    .decodePublicKey(hex: member.pubkeyHex)
                    .rawRepresentation
                let sharedSecret = try KeyAgreement.sharedSecret(
                    privateKey: adminPriv,
                    peerPublicKeyHex: member.pubkeyHex
                )
                let wrapKey = try rotationKDF.deriveWrapKey(sharedSecret: sharedSecret, newKeyID: newKeyIDData)
                let plaintext = RotationPlaintext(
                    kind: .rotation,
                    newTeamKeyBase64: newTeamKeyBytes.base64EncodedString(),
                    newKeyID: newKeyID,
                    priorKeyID: priorKeyID,
                    generatedAtMs: nowMs,
                    removedMemberID: nil
                )
                let blob = try rotationBlobCodec.encode(
                    plaintext,
                    recipientPubkey: peerPubData,
                    wrapKey: wrapKey
                )
                outboxRows.append(RotationOutboxRow(
                    peerPubkeyHex: member.pubkeyHex,
                    newKeyID: newKeyID,
                    priorKeyID: priorKeyID,
                    kind: .rotation,
                    peerMemberID: member.id,
                    blob: blob.bytes,
                    expiresAtMs: expiresAtMs,
                    createdAtMs: nowMs,
                    postedAtMs: nil
                ))
            }
        }

        // 5. Keystore-first (orphan file < orphan rows per 5.1.D contract).
        try TeamKeystore.writeTeamKey(newTeamKeyBytes, id: newKeyID, at: keystoreRoot)

        // 6. Atomic DB tx
        let newTeamKey = TeamKey(
            id: newKeyID,
            generatedAt: nowDate,
            deprecatedAt: nil,
            generatedByMemberID: selfMemberID
        )
        try database.commitRotation(
            newTeamKey: newTeamKey,
            priorTeamKeyID: priorKeyID,
            deprecatedAt: nowDate,
            removedMemberID: removedMember?.id,
            removedAt: removedMember != nil ? nowDate : nil,
            outboxRows: outboxRows
        )

        return PreparedRotation(
            newKeyID: newKeyID,
            priorKeyID: priorKeyID,
            outboxRows: outboxRows
        )
    }

}
