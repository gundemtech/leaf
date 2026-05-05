import Foundation

/// Encrypted opaque blob carrying invite payload (Phase 5.2.B).
///
/// Bytes layout: `[ ver:1B | admin_pubkey:32B | nonce:12B | ciphertext | tag:16B ]`.
/// Public envelope shape — whitepaper presence-relay.md §invite handshake.
/// AAD construction / JSON plaintext shape / nonce gen — moat в
/// `LeafCorePrivate/Prod/Crypto/`.
public struct InviteBlob: Sendable, Hashable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
}

/// Plaintext header parse result. No crypto.
///
/// Caller использует `adminPubkey` чтобы выполнить
/// `KeyAgreement.sharedSecret(privateKey: invitee_priv, peerPublicKeyHex: pubkey.hex)` →
/// `InviteKDF.deriveWrapKey(sharedSecret:, otp:)` → `wrapKey`,
/// затем `InviteBlobCodec.decode(blob, wrapKey:)`.
public struct InviteBlobHeader: Sendable, Hashable {
    public let version: UInt8
    public let adminPubkey: Data

    public init(version: UInt8, adminPubkey: Data) {
        self.version = version
        self.adminPubkey = adminPubkey
    }

    /// `0x02` для invite blob (отличается от envelope `0x01`).
    public static let currentVersion: UInt8 = 2
    /// 1B version + 32B X25519 admin pubkey.
    public static let prefixSize: Int = 33
    /// AES-GCM standard nonce.
    public static let nonceSize: Int = 12
    /// AES-GCM auth tag.
    public static let tagSize: Int = 16
    /// 1B ver + 32B pubkey + 12B nonce. Used as AAD by `ProdInviteBlobCodec`.
    public static let aadPrefixSize: Int = 45
    /// 1+32+12+16 — fixed overhead (excludes plaintext bytes).
    public static let fixedOverhead: Int = 61

    /// Read-only parse первых 33 байт. No crypto.
    /// Throws `LeafError.inviteBlobMalformed` если bytes < 33 / version != currentVersion.
    public static func peek(from blob: InviteBlob) throws -> InviteBlobHeader {
        let bytes = blob.bytes
        guard bytes.count >= prefixSize else {
            throw LeafError.inviteBlobMalformed
        }
        let version = bytes[bytes.startIndex]
        guard version == currentVersion else {
            throw LeafError.inviteBlobMalformed
        }
        let pubStart = bytes.index(bytes.startIndex, offsetBy: 1)
        let pubEnd = bytes.index(pubStart, offsetBy: 32)
        let adminPubkey = Data(bytes[pubStart..<pubEnd])
        return InviteBlobHeader(version: version, adminPubkey: adminPubkey)
    }
}
