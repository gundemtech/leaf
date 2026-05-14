import CryptoKit
import Foundation

/// Phase 5.2.A — `InviteKDF` protocol surface. Real impl —
/// `ProdInviteKDF` в LeafCorePrivate (gitignored moat: HKDF info string +
/// OTP→salt construction). Mirror discipline `EnvelopeCodec` / 5.1.C.
///
/// Derives 256-bit AES wrap key из ECDH shared secret + 6-digit OTP.
/// OTP — exactly 6 ASCII digits 0-9; impl throws `LeafError.invalidPayload`
/// otherwise.
public protocol InviteKDF: Sendable {
    func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey

    /// Track 5 / S3 — HMACs the OTP for server-side storage (`invites.otp_hash bytea`).
    /// Currently the Edge Function does NOT verify this hash (AES-GCM tag mismatch is
    /// the security path); populated for future server-side OTP rate-limit hardening.
    /// Salt label + HMAC construction live in `ProdInviteKDF` (LeafCorePrivate moat).
    func hashOTPForServerStorage(otp: String) -> Data
}

/// Phase-0 / CI заглушка. Реальный KDF — `ProdInviteKDF` в
/// LeafCorePrivate/Prod/Crypto/.
public struct UnimplementedInviteKDF: InviteKDF {
    public init() {}
    public func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey {
        throw LeafError.notImplemented
    }
    public func hashOTPForServerStorage(otp: String) -> Data {
        Data()
    }
}
