import CryptoKit
import Foundation

/// Phase Track-5 S5 — protocol for auto-shared team-event blob codec.
///
/// Encrypts `TeamEventPlaintext` under workspace `teamKey` (32B AES-256)
/// embedding `keyID` (16B UUID raw) in the envelope header. Public envelope
/// shape `[version:1B | keyID:16B | nonce:12B | ciphertext | tag:16B]` — same
/// byte layout as presence (0x01), invite (0x02), direct-message (0x03) blobs.
/// **Version byte 0x04** identifies this envelope type.
///
/// AAD construction + byte-slice ranges + JSONEncoder configuration live in
/// `LeafCorePrivate/Prod/Crypto/ProdTeamEventBlobCodec.swift` (moat).
public protocol TeamEventBlobCodec: Sendable {
    /// Encodes plaintext + seals under teamKey. Returns envelope bytes.
    /// - Parameters:
    ///   - plaintext: payload to encrypt.
    ///   - keyID: exactly 16 bytes (UUID `team_keys.id` raw bytes).
    ///   - teamKey: exactly 32 bytes raw AES-256 key.
    /// - Throws: `LeafError.teamEventBlobMalformed` on bad input sizes.
    func encode(_ plaintext: TeamEventPlaintext,
                keyID: Data,
                teamKey: Data) throws -> Data

    /// Decodes envelope under teamKey. Caller must peek envelope header first
    /// (`EnvelopeHeader.peek(from:)`) to resolve keyID → teamKey, then call this.
    /// - Throws: `LeafError.teamEventBlobMalformed` on short bytes / unknown
    ///   version / AES-GCM tag mismatch / JSON decode failure.
    func decode(_ bytes: Data, teamKey: Data) throws -> TeamEventPlaintext
}

/// Phase Track-5 S5 — CI / pre-prod stub. Real impl is `ProdTeamEventBlobCodec`
/// in LeafCorePrivate/Prod/Crypto/ (composition root through `#if LEAF_PROD`).
public struct UnimplementedTeamEventBlobCodec: TeamEventBlobCodec {
    public init() {}

    public func encode(_ plaintext: TeamEventPlaintext,
                       keyID: Data,
                       teamKey: Data) throws -> Data {
        throw LeafError.notImplemented
    }

    public func decode(_ bytes: Data, teamKey: Data) throws -> TeamEventPlaintext {
        throw LeafError.notImplemented
    }
}
