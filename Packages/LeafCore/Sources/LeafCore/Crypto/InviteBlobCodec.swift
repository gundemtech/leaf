import CryptoKit
import Foundation

/// AES-GCM-256 wrap/unwrap для invite payload (Phase 5.2.B).
///
/// Public surface — protocol + Unimplemented stub. Реальная impl
/// (`ProdInviteBlobCodec`) — moat в `LeafCorePrivate/Prod/Crypto/`.
public protocol InviteBlobCodec: Sendable {
    /// Сериализует plaintext (JSON), шифрует AES-GCM-256 под `wrapKey`,
    /// embedd'ит `adminPubkey` в header.
    /// - Parameters:
    ///   - plaintext: invite payload to encrypt.
    ///   - adminPubkey: ровно 32 bytes (admin's X25519 public).
    ///   - wrapKey: 32-byte AES key из `InviteKDF.deriveWrapKey`.
    /// - Returns: `InviteBlob` `[ver:1B|adminPubkey:32B|nonce:12B|ct|tag:16B]`.
    /// - Throws: `LeafError.inviteBlobMalformed` на bad input sizes / encoding failure.
    func encode(
        _ plaintext: InvitePlaintext,
        adminPubkey: Data,
        wrapKey: SymmetricKey
    ) throws -> InviteBlob

    /// Расшифровывает blob под `wrapKey`. Caller обязан ДО вызова peek'нуть header
    /// (`InviteBlobHeader.peek(from:)`), извлечь `adminPubkey`, выполнить
    /// X25519 ECDH + HKDF чтобы получить `wrapKey`.
    /// - Throws: `LeafError.inviteBlobMalformed` на short bytes / version mismatch /
    ///           AES-GCM tag fail (включая wrong wrapKey / wrong OTP) / JSON decode failure.
    func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext
}

/// Phase-0 / CI заглушка. Реальный codec — `ProdInviteBlobCodec`
/// в `LeafCorePrivate/Prod/Crypto/` (Phase 5.2.B moat).
public struct UnimplementedInviteBlobCodec: InviteBlobCodec {
    public init() {}
    public func encode(
        _ plaintext: InvitePlaintext,
        adminPubkey: Data,
        wrapKey: SymmetricKey
    ) throws -> InviteBlob {
        throw LeafError.notImplemented
    }
    public func decode(_ blob: InviteBlob, wrapKey: SymmetricKey) throws -> InvitePlaintext {
        throw LeafError.notImplemented
    }
}
