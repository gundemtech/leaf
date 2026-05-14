import CryptoKit
import Foundation

/// Phase Track-5 S4 — protocol for direct-message blob codec.
///
/// Encrypts `DirectMessagePlaintext` under workspace `teamKey` (32B AES-256)
/// embedding `keyID` (16B UUID raw) in the envelope header. Public envelope
/// shape `[version:1B | keyID:16B | nonce:12B | ciphertext | tag:16B]` —
/// same byte layout as `PresenceSnapshot` envelope (architecture.md §Presence
/// distribution). Version byte distinguishes DM blob from other envelopes.
///
/// AAD construction + byte-slice ranges + JSONEncoder configuration live in
/// `LeafCorePrivate/Prod/Crypto/ProdDirectMessageBlobCodec.swift` (moat).
public protocol DirectMessageBlobCodec: Sendable {
    /// Encodes plaintext + seals under teamKey. Returns envelope bytes.
    /// - Parameters:
    ///   - plaintext: payload to encrypt.
    ///   - keyID: exactly 16 bytes (UUID `team_keys.id` raw bytes).
    ///   - teamKey: exactly 32 bytes raw AES-256 key.
    /// - Throws: `LeafError.directMessageBlobMalformed` on bad input sizes.
    func encode(_ plaintext: DirectMessagePlaintext,
                keyID: Data,
                teamKey: Data) throws -> Data

    /// Decodes envelope under teamKey. Caller must peek envelope header first
    /// (`EnvelopeHeader.peek(from:)`) to resolve keyID → teamKey, then call this.
    /// - Throws: `LeafError.directMessageBlobMalformed` on short bytes / unknown
    ///   version / AES-GCM tag mismatch / JSON decode failure.
    func decode(_ bytes: Data, teamKey: Data) throws -> DirectMessagePlaintext
}

/// Phase Track-5 S4 — CI / pre-prod stub. Real impl is `ProdDirectMessageBlobCodec`
/// in LeafCorePrivate/Prod/Crypto/ (composition root through `#if LEAF_PROD`).
public struct UnimplementedDirectMessageBlobCodec: DirectMessageBlobCodec {
    public init() {}

    public func encode(_ plaintext: DirectMessagePlaintext,
                       keyID: Data,
                       teamKey: Data) throws -> Data {
        throw LeafError.notImplemented
    }

    public func decode(_ bytes: Data, teamKey: Data) throws -> DirectMessagePlaintext {
        throw LeafError.notImplemented
    }
}
