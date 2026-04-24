import Foundation

/// Заголовок encrypted presence envelope.
/// Bytes layout: [version:1B | keyID:16B | nonce:12B | ciphertext | tag:16B]
/// Конкретные значения и serialization живут в LeafCorePrivate (Phase 2+).
public struct EnvelopeHeader: Sendable, Hashable {
    public let version: UInt8
    public let keyID: Data

    public init(version: UInt8, keyID: Data) {
        self.version = version
        self.keyID = keyID
    }

    public static let currentVersion: UInt8 = 1
}

public protocol EnvelopeCodec: Sendable {
    func encode(_ snapshot: PresenceSnapshot, teamKey: Data) throws -> Data
    func decode(_ bytes: Data, teamKey: Data) throws -> PresenceSnapshot
}

/// Phase-0 / CI заглушка. Реальный codec на CryptoKit.AES.GCM — Phase 2.
public struct UnimplementedEnvelopeCodec: EnvelopeCodec {
    public init() {}
    public func encode(_ snapshot: PresenceSnapshot, teamKey: Data) throws -> Data {
        throw LeafError.notImplemented
    }
    public func decode(_ bytes: Data, teamKey: Data) throws -> PresenceSnapshot {
        throw LeafError.notImplemented
    }
}
