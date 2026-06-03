import CryptoKit
import Foundation

/// Phase 5.2.A — `InviteKDF` protocol surface. Real impl —
/// `ProdInviteKDF` in LeafCorePrivate (gitignored moat: HKDF info string +
/// OTP→salt construction). Mirror discipline `EnvelopeCodec` / 5.1.C.
///
/// Derives a 256-bit AES wrap key from the ECDH shared secret and an optional
/// OTP. The per-pair X25519 ECDH `sharedSecret` is the sole 256-bit entropy
/// source; the OTP, when supplied, folds a second factor into the salt.
public protocol InviteKDF: Sendable {
    /// - Parameter otp: Either a 6-digit ASCII OTP, or the empty string `""`
    ///   for the **no-OTP mode** — used by every requireOTP=false URL invite
    ///   (`InviteService` / `InviteAcceptService`) and by M027 closed-mode
    ///   join-by-code (`JoinRequestService.approve` / `acceptApproved`). Both
    ///   sides must pass the SAME otp so the derived key matches.
    /// - Throws: `LeafError.invalidPayload` only when a NON-empty OTP is not
    ///   exactly 6 ASCII digits. `otp == ""` is valid and must NOT throw —
    ///   rejecting it broke every no-OTP invite accept with NSError code 13.
    func deriveWrapKey(sharedSecret: SharedSecret, otp: String) throws -> SymmetricKey

    /// Track 5 / S3 — HMACs the OTP for server-side storage (`invites.otp_hash bytea`).
    /// Currently the Edge Function does NOT verify this hash (AES-GCM tag mismatch is
    /// the security path); populated for future server-side OTP rate-limit hardening.
    /// Salt label + HMAC construction live in `ProdInviteKDF` (LeafCorePrivate moat).
    func hashOTPForServerStorage(otp: String) -> Data
}

/// Phase-0 / CI stub. The real KDF is `ProdInviteKDF` in
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
