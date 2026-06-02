import Foundation

/// Phase 5.1.B — team key rotation **metadata** (contract §7). Pure DB row;
/// raw 32-byte AES-256 material lives in the keystore file (5.1.D), NOT in the DB.
/// Stored in the `team_keys` table (Schema.TeamKeys, M008/M019).
///
/// `id` — rotation UUID v4. Embedded as 16-byte `keyID` in the envelope (contract §6).
///
/// `deprecatedAt` IS NULL = current rotation. Set on rotation (Phase 5.3).
///
/// Phase Track-5 S2 — `workspaceID` field added (M019 backfilled column).
/// Forever-retained per `team_keys` design: old rows are needed to decrypt
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
