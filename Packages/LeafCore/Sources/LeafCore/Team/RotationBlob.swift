import Foundation

/// Encrypted opaque blob carrying rotation payload (Phase 5.3.B).
///
/// Bytes layout:
/// `[ ver:1B | prior_keyID:16B | new_keyID:16B | recipient_pubkey:32B | nonce:12B | ciphertext | tag:16B ]`.
///
/// Public envelope shape — whitepaper presence-relay.md §key rotation flow.
/// AAD construction / JSON plaintext shape / nonce gen — moat in
/// `LeafCorePrivate/Prod/Crypto/`.
///
/// `ver = 0x03` distinguishes it from envelope (0x01) and invite (0x02). Domain
/// separation enforced at two independent layers — version byte +
/// distinct HKDF info string (constant — moat in `LeafCorePrivate`).
public struct RotationBlob: Sendable, Hashable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

/// Plaintext header parse result. No crypto.
///
/// Caller uses `recipientPubkey` + `newKeyID` to derive wrapKey:
///   - .rotation: `KeyAgreement.sharedSecret(privateKey: peer_priv, peerPublicKeyHex: admin_pub)`
///                → `RotationKDF.deriveWrapKey(sharedSecret:, newKeyID:)` → `wrapKey`
///   - .tombstone: `wrapKey = SymmetricKey(data: priorTeamKey)` (raw 32B,
///                 shared among all team members prior to rotation)
public struct RotationBlobHeader: Sendable, Hashable {
    public let version: UInt8
    public let priorKeyID: Data       // 16B raw UUID bytes
    public let newKeyID: Data         // 16B raw UUID bytes (== priorKeyID for tombstone)
    public let recipientPubkey: Data  // 32B X25519 public key

    public init(version: UInt8, priorKeyID: Data, newKeyID: Data, recipientPubkey: Data) {
        self.version = version
        self.priorKeyID = priorKeyID
        self.newKeyID = newKeyID
        self.recipientPubkey = recipientPubkey
    }

    /// `0x03` for rotation blob (envelope = `0x01`, invite = `0x02`).
    public static let currentVersion: UInt8 = 3
    public static let priorKeyIDSize: Int = 16
    public static let newKeyIDSize: Int = 16
    public static let recipientPubkeySize: Int = 32
    /// 1B ver + 16B priorKeyID + 16B newKeyID + 32B recipientPubkey.
    public static let prefixSize: Int = 65
    /// AES-GCM standard nonce.
    public static let nonceSize: Int = 12
    /// AES-GCM auth tag.
    public static let tagSize: Int = 16
    /// 65B prefix + 12B nonce — used as AAD by `ProdRotationBlobCodec`.
    public static let aadPrefixSize: Int = 77
    /// 65 + 12 + 16 — fixed overhead (excludes plaintext bytes).
    public static let fixedOverhead: Int = 93

    /// Read-only parse of the first 65 bytes. No crypto.
    /// Throws `LeafError.rotationBlobMalformed` if bytes < 65 / version != currentVersion.
    public static func peek(from blob: RotationBlob) throws -> RotationBlobHeader {
        let bytes = blob.bytes
        guard bytes.count >= prefixSize else {
            throw LeafError.rotationBlobMalformed
        }
        let version = bytes[bytes.startIndex]
        guard version == currentVersion else {
            throw LeafError.rotationBlobMalformed
        }

        let priorStart = bytes.index(bytes.startIndex, offsetBy: 1)
        let priorEnd = bytes.index(priorStart, offsetBy: priorKeyIDSize)
        let newEnd = bytes.index(priorEnd, offsetBy: newKeyIDSize)
        let recipientEnd = bytes.index(newEnd, offsetBy: recipientPubkeySize)

        let priorKeyID = Data(bytes[priorStart..<priorEnd])
        let newKeyID = Data(bytes[priorEnd..<newEnd])
        let recipientPubkey = Data(bytes[newEnd..<recipientEnd])

        return RotationBlobHeader(version: version,
                                  priorKeyID: priorKeyID,
                                  newKeyID: newKeyID,
                                  recipientPubkey: recipientPubkey)
    }
}
