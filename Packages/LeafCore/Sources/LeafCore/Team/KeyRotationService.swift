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
}
