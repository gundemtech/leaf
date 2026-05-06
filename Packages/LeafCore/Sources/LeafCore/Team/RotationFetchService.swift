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
        // Filled in subsequent tasks (Task 4-6).
        return .empty
    }
}
