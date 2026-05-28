import CryptoKit
import Foundation

/// Phase 5.2.A — pure passthrough wrapper над CryptoKit X25519 ECDH +
/// hex-decode для invitee/admin pubkey exchange. No state. Mirror
/// enum-namespace style of `IdentityService` / `TeamKeystore`.
///
/// ECDH symmetric: same `SharedSecret` bytes когда вызывается из обеих
/// сторон keypair pair. Caller (5.2.B `ProdInviteBlobCodec`) feeds the
/// resulting `SharedSecret` в HKDF-SHA256 (`InviteKDF.deriveWrapKey`).
public enum KeyAgreement {

    /// X25519 ECDH. Decodes peer pub from hex, computes shared secret.
    /// 32 bytes (constant-time compare semantic).
    /// - Throws: `LeafError.invalidPayload` если hex bad / wrong length;
    ///   `LeafError.lowOrderPoint` если peer point low-order / small-subgroup
    ///   (rejected by CryptoKit) либо shared secret all-zero (RFC 7748 §6.1).
    public static func sharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyHex: String
    ) throws -> SharedSecret {
        let peerPub = try decodePublicKey(hex: peerPublicKeyHex)
        let secret: SharedSecret
        do {
            secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPub)
        } catch is CryptoKitError {
            // macOS ≥ 26 CryptoKit rejects low-order / small-subgroup peer points at
            // the agreement step (corecrypto −7). Surface as a dedicated domain error
            // so callers (invite / accept / rotation) treat it as a rejected peer key,
            // not an opaque crypto failure.
            throw LeafError.lowOrderPoint
        }
        // Defense-in-depth for OS versions whose X25519 returns an all-zero shared
        // secret instead of throwing (RFC 7748 §6.1 contributory-behaviour check).
        // Constant-time: OR-accumulate every byte, single branch on the aggregate.
        var acc: UInt8 = 0
        secret.withUnsafeBytes { raw in
            for byte in raw { acc |= byte }
        }
        if acc == 0 { throw LeafError.lowOrderPoint }
        return secret
    }

    /// Hex → `Curve25519.KeyAgreement.PublicKey`. Lenient case (accepts
    /// 0-9 a-f A-F); strict length (exactly 64 chars).
    /// - Throws: `LeafError.invalidPayload` если hex bad / wrong length.
    public static func decodePublicKey(hex: String) throws -> Curve25519.KeyAgreement.PublicKey {
        let raw = try decodeHex32(hex)
        return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    // MARK: - Internals

    private static func decodeHex32(_ hex: String) throws -> Data {
        guard hex.count == 64 else {
            throw LeafError.invalidPayload
        }
        var out = Data(capacity: 32)
        var iter = hex.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let highNibble = nibble(hi), let lowNibble = nibble(lo) else {
                throw LeafError.invalidPayload
            }
            out.append((highNibble << 4) | lowNibble)
        }
        return out
    }

    private static func nibble(_ c: Character) -> UInt8? {
        // swiftlint:disable force_unwrapping
        // Reason: switch cases narrow `c` to ASCII ranges "0"–"9" / "a"–"f" / "A"–"F";
        // `Character.asciiValue` is guaranteed non-nil for ASCII characters, as is the
        // statically-known literal `Character("0").asciiValue` etc.
        switch c {
        case "0"..."9": return UInt8(c.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return UInt8(c.asciiValue! - Character("a").asciiValue!) + 10
        case "A"..."F": return UInt8(c.asciiValue! - Character("A").asciiValue!) + 10
        default: return nil
        }
        // swiftlint:enable force_unwrapping
    }
}
