import CryptoKit
import Foundation

/// AES-GCM-256 wrap/unwrap для rotation payload (Phase 5.3.B).
///
/// Public surface — protocol + Unimplemented stub. Реальная impl
/// (`ProdRotationBlobCodec`) — moat в `LeafCorePrivate/Prod/Crypto/`.
///
/// Domain-separated от `InviteBlobCodec` через distinct version byte (0x03 vs 0x02),
/// distinct AAD layout (77B vs 45B prefix), and distinct HKDF info string (см.
/// `RotationKDF`). Leaked invite wrapKey не должен decrypt'ить rotation blob.
///
/// `priorKeyID` + `newKeyID` приходят из `plaintext` и embedд'ятся в header.
/// `recipientPubkey` — recipient's X25519 public (для AAD audit binding).
public protocol RotationBlobCodec: Sendable {
    /// Сериализует plaintext (JSON), шифрует AES-GCM-256 под `wrapKey`,
    /// embeds `priorKeyID` / `newKeyID` (from plaintext) + `recipientPubkey` в header.
    /// - Parameters:
    ///   - plaintext: rotation payload to encrypt.
    ///   - recipientPubkey: ровно 32 bytes (recipient's X25519 public).
    ///   - wrapKey: 32-byte AES key — derived via `RotationKDF.deriveWrapKey` для
    ///              .rotation (ECDH path), либо raw prior teamKey для .tombstone.
    /// - Returns: `RotationBlob` `[ver:1B|priorKeyID:16B|newKeyID:16B|recipientPubkey:32B|nonce:12B|ct|tag:16B]`.
    /// - Throws: `LeafError.rotationBlobMalformed` на bad input sizes / encoding failure.
    func encode(_ plaintext: RotationPlaintext,
                recipientPubkey: Data,
                wrapKey: SymmetricKey) throws -> RotationBlob

    /// Расшифровывает blob под `wrapKey`. Caller обязан ДО вызова peek'нуть header
    /// (`RotationBlobHeader.peek(from:)`), извлечь `priorKeyID` / `newKeyID` /
    /// `recipientPubkey`, derive wrapKey (либо ECDH+HKDF для .rotation, либо
    /// загрузить raw prior teamKey для .tombstone).
    /// - Throws: `LeafError.rotationBlobMalformed` на short bytes / version mismatch /
    ///           AES-GCM tag fail (включая wrong wrapKey) / JSON decode failure /
    ///           cross-field invariant violation между kind and other plaintext fields.
    func decode(_ blob: RotationBlob, wrapKey: SymmetricKey) throws -> RotationPlaintext
}

/// Phase-0 / CI заглушка. Реальный codec — `ProdRotationBlobCodec`
/// в `LeafCorePrivate/Prod/Crypto/` (Phase 5.3.B moat).
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
