import CryptoKit
import Foundation

/// Phase 5.3.B — `RotationKDF` protocol surface. Real impl —
/// `ProdRotationKDF` в `LeafCorePrivate/Prod/Crypto/` (gitignored moat:
/// HKDF info string + salt construction). Mirror discipline `InviteKDF` / 5.2.A.
///
/// Derives 256-bit AES wrap key from ECDH shared secret + per-rotation
/// salt (`newKeyID` 16B raw UUID). **No OTP** — peer pubkey trust-validated
/// через invite handshake (5.2). ECDH(admin_priv, peer.pub) authenticated by
/// `team_members` row membership.
///
/// `newKeyID` 16B serves as HKDF salt — fresh wrapKey per rotation even if
/// same admin↔peer ECDH pair re-derives same `SharedSecret`.
///
/// Used only для `.rotation` kind. `.tombstone` kind использует raw prior
/// teamKey directly (32B → SymmetricKey без KDF), per architecture overview AD #6.
public protocol RotationKDF: Sendable {
    /// HKDF-SHA256 derivation. `newKeyID` MUST be ровно 16 bytes raw UUID;
    /// throws `LeafError.invalidPayload` иначе.
    func deriveWrapKey(sharedSecret: SharedSecret, newKeyID: Data) throws -> SymmetricKey
}

/// Phase-0 / CI заглушка. Реальный KDF — `ProdRotationKDF` в
/// `LeafCorePrivate/Prod/Crypto/`.
public struct UnimplementedRotationKDF: RotationKDF {
    public init() {}
    public func deriveWrapKey(sharedSecret: SharedSecret, newKeyID: Data) throws -> SymmetricKey {
        throw LeafError.notImplemented
    }
}
