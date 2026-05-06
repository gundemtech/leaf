import Foundation
import CryptoKit

/// Phase 5.3.E — peer-side counterpart to 5.3.D `KeyRotationService`. Drains
/// pending key-rotation blobs from relay (peer-pubkey-keyed mailbox), unwraps
/// each (ECDH+HKDF for `.rotation` via brute-force admin candidates; raw prior
/// teamKey for `.tombstone`), installs locally idempotently, and acks the relay.
///
/// Discriminator: `header.priorKeyID == header.newKeyID` ⇒ `.tombstone` (no
/// new teamKey to install; mark self removed). Otherwise `.rotation` (try
/// each admin pubkey for ECDH+HKDF until decrypt succeeds).
///
/// Idempotency guarantees:
/// - `Database.insertTeamKeyIfAbsent` swallows duplicate-id (mid-install crash retry).
/// - `Database.markTeamMemberRemoved` silently no-ops on already-removed.
/// - Ack failure → next tick retries (relay idempotent on DELETE, install steps idempotent).
///
/// Public API:
/// - `tick() async -> RotationFetchOutcome` — single fetch+install pass.
public struct RotationFetchService: Sendable {
    private let database: Database
    private let relayClient: RelayClient
    private let rotationKDF: any RotationKDF
    private let rotationBlobCodec: any RotationBlobCodec
    private let keystoreRoot: URL
    private let now: @Sendable () -> Date
    private let identity: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey

    public init(
        database: Database,
        relayClient: RelayClient,
        rotationKDF: any RotationKDF,
        rotationBlobCodec: any RotationBlobCodec,
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        identity: (@Sendable () throws -> Curve25519.KeyAgreement.PrivateKey)? = nil
    ) {
        self.database = database
        self.relayClient = relayClient
        self.rotationKDF = rotationKDF
        self.rotationBlobCodec = rotationBlobCodec
        self.keystoreRoot = keystoreRoot
        self.now = now
        self.identity = identity ?? { try IdentityService.ensureLocalIdentity(at: keystoreRoot) }
    }

    // MARK: - Public API

    /// Drains relay mailbox once. Continue-on-error per blob — failures
    /// accumulate in `skipped`. Returns aggregate outcome.
    public func tick() async -> RotationFetchOutcome {
        // 1. Preflight — graceful no-op if no org / no identity.
        guard let org = try? database.readOrg() else {
            return .empty
        }
        guard let selfPriv = try? identity() else {
            return .empty
        }
        let selfPubHex = hexEncodePubkey(selfPriv.publicKey.rawRepresentation)

        // 2. Drain mailbox.
        let blobs: [RotationFetched]
        do {
            blobs = try await relayClient.fetchPendingRotations(forPeerPubkeyHex: selfPubHex)
        } catch {
            return .empty
        }
        if blobs.isEmpty { return .empty }

        // 3. Iterate, continue-on-error.
        var installed = 0
        var tombstoneApplied = 0
        var skipped = 0

        for fetched in blobs {
            let rotationBlob = RotationBlob(bytes: fetched.blob)
            let header: RotationBlobHeader
            do {
                header = try RotationBlobHeader.peek(from: rotationBlob)
            } catch {
                skipped += 1
                continue
            }

            // Discriminator: tombstone iff prior == new.
            let isTombstone = header.priorKeyID == header.newKeyID

            let applied: Bool
            if isTombstone {
                applied = await processTombstone(blob: rotationBlob, header: header,
                                                 orgID: org.id, selfPubHex: selfPubHex)
                if applied { tombstoneApplied += 1 }
            } else {
                applied = await processRotation(blob: rotationBlob, header: header,
                                                orgID: org.id, selfPriv: selfPriv,
                                                selfPubHex: selfPubHex)
                if applied { installed += 1 }
            }

            if applied {
                try? await relayClient.ackRotation(rotationID: fetched.rotationID)
            } else {
                skipped += 1
            }
        }

        return RotationFetchOutcome(
            fetched: blobs.count,
            installed: installed,
            tombstoneApplied: tombstoneApplied,
            skipped: skipped
        )
    }

    // MARK: - Internals

    private func processTombstone(blob: RotationBlob, header: RotationBlobHeader,
                                  orgID: String, selfPubHex: String) async -> Bool {
        // Filled in Task 5.
        return false
    }

    private func processRotation(blob: RotationBlob, header: RotationBlobHeader,
                                 orgID: String,
                                 selfPriv: Curve25519.KeyAgreement.PrivateKey,
                                 selfPubHex: String) async -> Bool {
        // Filled in Task 6.
        return false
    }

    private func hexEncodePubkey(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
