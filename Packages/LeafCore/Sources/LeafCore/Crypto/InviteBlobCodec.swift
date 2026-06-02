import CryptoKit
import Foundation

/// AES-GCM-256 wrap/unwrap for the invite payload (Phase 5.2.B).
///
/// Public surface — protocol + Unimplemented stub. The real impl
/// (`ProdInviteBlobCodec`) is moat in `LeafCorePrivate/Prod/Crypto/`.
public protocol InviteBlobCodec: Sendable {
    /// Serializes the plaintext (JSON), encrypts AES-GCM-256 under `wrapKey`,
    /// embeds `adminPubkey` in the header.
    /// - Parameters:
    ///   - plaintext: invite payload to encrypt.
    ///   - adminPubkey: exactly 32 bytes (admin's X25519 public).
    ///   - wrapKey: 32-byte AES key from `InviteKDF.deriveWrapKey`.
    /// - Returns: `InviteBlob` `[ver:1B|adminPubkey:32B|nonce:12B|ct|tag:16B]`.
    /// - Throws: `LeafError.inviteBlobMalformed` on bad input sizes / encoding failure.
    func encode(_ plaintext: InvitePlaintext,
                adminPubkey: Data,
                wrapKey: SymmetricKey) throws -> InviteBlob

    /// Decrypts the blob under `wrapKey`. Before calling, the caller MUST peek the header
    /// (`InviteBlobHeader.peek(from:)`), extract `adminPubkey`, and perform
    /// X25519 ECDH + HKDF to obtain `wrapKey`.
    /// - Throws: `LeafError.inviteBlobMalformed` on short bytes / version mismatch /
    ///           AES-GCM tag fail (including wrong wrapKey / wrong OTP) / JSON decode failure.
    func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext
}

/// Phase-0 / CI stub. The real codec is `ProdInviteBlobCodec`
/// in `LeafCorePrivate/Prod/Crypto/` (Phase 5.2.B moat).
public struct UnimplementedInviteBlobCodec: InviteBlobCodec {
    public init() {}
    public func encode(_ plaintext: InvitePlaintext,
                       adminPubkey: Data,
                       wrapKey: SymmetricKey) throws -> InviteBlob {
        throw LeafError.notImplemented
    }
    public func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
        throw LeafError.notImplemented
    }
}
