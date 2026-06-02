import Foundation

/// Header of the encrypted presence envelope.
/// Bytes layout: [version:1B | keyID:16B | nonce:12B | ciphertext | tag:16B]
/// Public envelope shape — whitepaper presence-relay.md §6.
/// The exact AAD/nonce/byte assembly is moat in `LeafCorePrivate/Prod/Crypto/`.
public struct EnvelopeHeader: Sendable, Hashable {
    public let version: UInt8
    public let keyID: Data

    public init(version: UInt8, keyID: Data) {
        self.version = version
        self.keyID = keyID
    }

    public static let currentVersion: UInt8 = 1

    /// Size of the plaintext header prefix in the envelope: 1B version + 16B keyID.
    public static let prefixSize: Int = 17

    /// Read-only parse of the first 17 bytes of the envelope (1B version + 16B keyID).
    /// No crypto. The caller uses the returned `keyID` to find the
    /// matching teamKey in the keystore (history rotation), then calls
    /// `EnvelopeCodec.decode(bytes, teamKey)`.
    /// Throws `LeafError.corruptedEnvelope` if bytes are shorter than 17 or the version
    /// does not equal `currentVersion` (per architecture contract §12: implementations
    /// MUST reject unknown versions).
    public static func peek(from bytes: Data) throws -> EnvelopeHeader {
        guard bytes.count >= prefixSize else {
            throw LeafError.corruptedEnvelope
        }
        let version = bytes[bytes.startIndex]
        guard version == currentVersion else {
            throw LeafError.corruptedEnvelope
        }
        let keyIDStart = bytes.index(bytes.startIndex, offsetBy: 1)
        let keyIDEnd = bytes.index(keyIDStart, offsetBy: 16)
        let keyID = Data(bytes[keyIDStart..<keyIDEnd])
        return EnvelopeHeader(version: version, keyID: keyID)
    }
}

public protocol EnvelopeCodec: Sendable {
    /// Serializes the snapshot and encrypts it under `teamKey`, embedding `keyID` in the header.
    /// - Parameters:
    ///   - snapshot: payload to serialise + encrypt.
    ///   - keyID: exactly 16 bytes (UUID `team_keys.id` raw bytes).
    ///   - teamKey: exactly 32 bytes raw AES-256 key.
    /// - Returns: bytes envelope `[ver:1B|keyID:16B|nonce:12B|ct|tag:16B]`.
    /// - Throws: `LeafError.corruptedEnvelope` on bad input sizes.
    func encode(_ snapshot: PresenceSnapshot,
                keyID: Data,
                teamKey: Data) throws -> Data

    /// Decrypts the envelope under `teamKey`. Before calling, the caller MUST
    /// peek the header (`EnvelopeHeader.peek(from:)`) and find the
    /// teamKey by `header.keyID` in the keystore (history rotation).
    /// - Throws: `LeafError.corruptedEnvelope` on short bytes / unknown version /
    ///           AES-GCM tag mismatch / JSON decode failure.
    func decode(_ bytes: Data, teamKey: Data) throws -> PresenceSnapshot
}

/// Phase-0 / CI stub. The real codec is `ProdEnvelopeCodec`
/// in LeafCorePrivate/Prod/Crypto/ (Phase 5.1.C).
public struct UnimplementedEnvelopeCodec: EnvelopeCodec {
    public init() {}
    public func encode(_ snapshot: PresenceSnapshot,
                       keyID: Data,
                       teamKey: Data) throws -> Data {
        throw LeafError.notImplemented
    }
    public func decode(_ bytes: Data, teamKey: Data) throws -> PresenceSnapshot {
        throw LeafError.notImplemented
    }
}
