import Foundation

/// Заголовок encrypted presence envelope.
/// Bytes layout: [version:1B | keyID:16B | nonce:12B | ciphertext | tag:16B]
/// Public envelope shape — whitepaper presence-relay.md §6.
/// Точный AAD/nonce/byte assembly — moat в `LeafCorePrivate/Prod/Crypto/`.
public struct EnvelopeHeader: Sendable, Hashable {
    public let version: UInt8
    public let keyID: Data

    public init(version: UInt8, keyID: Data) {
        self.version = version
        self.keyID = keyID
    }

    public static let currentVersion: UInt8 = 1

    /// Размер plaintext header prefix в envelope: 1B version + 16B keyID.
    public static let prefixSize: Int = 17

    /// Read-only parse первых 17 байт envelope (1B version + 16B keyID).
    /// No crypto. Caller использует возвращённый `keyID`, чтобы найти
    /// соответствующий teamKey в keystore (history rotation), потом вызывает
    /// `EnvelopeCodec.decode(bytes, teamKey)`.
    /// Throws `LeafError.corruptedEnvelope` если bytes короче 17 или version
    /// не равна `currentVersion` (per architecture contract §12: implementations
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
    /// Сериализует snapshot и шифрует под `teamKey`, embedd'ит `keyID` в header.
    /// - Parameters:
    ///   - snapshot: payload to serialise + encrypt.
    ///   - keyID: ровно 16 bytes (UUID `team_keys.id` raw bytes).
    ///   - teamKey: ровно 32 bytes raw AES-256 key.
    /// - Returns: bytes envelope `[ver:1B|keyID:16B|nonce:12B|ct|tag:16B]`.
    /// - Throws: `LeafError.corruptedEnvelope` на bad input sizes.
    func encode(_ snapshot: PresenceSnapshot,
                keyID: Data,
                teamKey: Data) throws -> Data

    /// Расшифровывает envelope под `teamKey`. Caller обязан ДО вызова
    /// peek'нуть header (`EnvelopeHeader.peek(from:)`) и найти
    /// teamKey по `header.keyID` в keystore (history rotation).
    /// - Throws: `LeafError.corruptedEnvelope` на short bytes / unknown version /
    ///           AES-GCM tag mismatch / JSON decode failure.
    func decode(_ bytes: Data, teamKey: Data) throws -> PresenceSnapshot
}

/// Phase-0 / CI заглушка. Реальный codec — `ProdEnvelopeCodec`
/// в LeafCorePrivate/Prod/Crypto/ (Phase 5.1.C).
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
