import Foundation

/// Phase 5.1.B — team key rotation **metadata** (contract §7). Pure DB row;
/// raw 32-byte AES-256 material живёт в keystore-файле (5.1.D), НЕ в DB.
/// Хранится в `team_keys` таблице (Schema.TeamKeys, M008); forever-retained
/// чтобы decrypt'ить past `presence_history` под предыдущими rotation'ами
/// (contract §12).
///
/// `id` — rotation UUID v4. Embedded as 16-byte `keyID` в envelope (contract §6);
/// hex-UUID ↔ 16B encoding — забота `EnvelopeCodec` (5.1.C), не этого type'а.
///
/// `deprecatedAt` IS NULL = current rotation. Set при rotation (Phase 5.3 flow).
public struct TeamKey: Sendable, Hashable {
    public let id: String
    public let generatedAt: Date
    public let deprecatedAt: Date?
    public let generatedByMemberID: String

    public init(
        id: String,
        generatedAt: Date,
        deprecatedAt: Date?,
        generatedByMemberID: String
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.deprecatedAt = deprecatedAt
        self.generatedByMemberID = generatedByMemberID
    }
}
