import Foundation

/// Phase 5.1.B — team key rotation **metadata** (contract §7). Pure DB row;
/// raw 32-byte AES-256 material живёт в keystore-файле (5.1.D), НЕ в DB.
/// Хранится в `team_keys` таблице (Schema.TeamKeys, M008/M019).
///
/// `id` — rotation UUID v4. Embedded as 16-byte `keyID` в envelope (contract §6).
///
/// `deprecatedAt` IS NULL = current rotation. Set при rotation (Phase 5.3).
///
/// Phase Track-5 S2 — `workspaceID` field added (M019 backfilled column).
/// Forever-retained per `team_keys` design: old rows нужны для decrypt'а
/// past presence_history (contract §12). Back-compat init (sentinel
/// `workspaceID = ""`) was deleted in Task 12 cleanup; all call sites must
/// provide `workspaceID` explicitly.
public struct TeamKey: Sendable, Hashable {
    public let id: String
    public let workspaceID: String
    public let generatedAt: Date
    public let deprecatedAt: Date?
    public let generatedByMemberID: String

    public init(
        id: String,
        workspaceID: String,
        generatedAt: Date,
        deprecatedAt: Date?,
        generatedByMemberID: String
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.generatedAt = generatedAt
        self.deprecatedAt = deprecatedAt
        self.generatedByMemberID = generatedByMemberID
    }

}
