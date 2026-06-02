import CryptoKit
import Foundation

/// AES-GCM-256 wrap/unwrap for the rotation payload (Phase 5.3.B).
///
/// Public surface — protocol + Unimplemented stub. The real impl
/// (`ProdRotationBlobCodec`) is moat in `LeafCorePrivate/Prod/Crypto/`.
///
/// Domain-separated from `InviteBlobCodec` via a distinct version byte (0x03 vs 0x02),
/// distinct AAD layout (77B vs 45B prefix), and distinct HKDF info string (see
/// `RotationKDF`). A leaked invite wrapKey must not decrypt a rotation blob.
///
/// `priorKeyID` + `newKeyID` come from `plaintext` and are embedded in the header.
/// `recipientPubkey` — recipient's X25519 public (for AAD audit binding).
public protocol RotationBlobCodec: Sendable {
    /// Serializes plaintext (JSON), encrypts it with AES-GCM-256 under `wrapKey`,
    /// embeds `priorKeyID` / `newKeyID` (from plaintext) + `recipientPubkey` in the header.
    /// - Parameters:
    ///   - plaintext: rotation payload to encrypt.
    ///   - recipientPubkey: exactly 32 bytes (recipient's X25519 public).
    ///   - wrapKey: 32-byte AES key — derived via `RotationKDF.deriveWrapKey` for
    ///              .rotation (ECDH path), or the raw prior teamKey for .tombstone.
    /// - Returns: `RotationBlob` `[ver:1B|priorKeyID:16B|newKeyID:16B|recipientPubkey:32B|nonce:12B|ct|tag:16B]`.
    /// - Throws: `LeafError.rotationBlobMalformed` on bad input sizes / encoding failure.
    func encode(_ plaintext: RotationPlaintext,
                recipientPubkey: Data,
                wrapKey: SymmetricKey) throws -> RotationBlob

    /// Decrypts the blob under `wrapKey`. The caller MUST peek the header
    /// (`RotationBlobHeader.peek(from:)`) BEFORE calling, extract `priorKeyID` / `newKeyID` /
    /// `recipientPubkey`, and derive wrapKey (either ECDH+HKDF for .rotation, or
    /// load the raw prior teamKey for .tombstone).
    /// - Throws: `LeafError.rotationBlobMalformed` on short bytes / version mismatch /
    ///           AES-GCM tag fail (including wrong wrapKey) / JSON decode failure /
    ///           cross-field invariant violation between kind and other plaintext fields.
    func decode(_ blob: RotationBlob, wrapKey: SymmetricKey) throws -> RotationPlaintext
}

/// Phase-0 / CI stub. The real codec is `ProdRotationBlobCodec`
/// in `LeafCorePrivate/Prod/Crypto/` (Phase 5.3.B moat).
public struct UnimplementedRotationBlobCodec: RotationBlobCodec {
    public init() {}
    public func encode(_ plaintext: RotationPlaintext,
                       recipientPubkey: Data,
                       wrapKey: SymmetricKey) throws -> RotationBlob {
        throw LeafError.notImplemented
    }
    public func decode(_ blob: RotationBlob, wrapKey: SymmetricKey) throws -> RotationPlaintext {
        throw LeafError.notImplemented
    }
}
