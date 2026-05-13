import Foundation

/// Phase 5.1.B — long-term member identity + X25519 public key (contract §4, §7).
/// Хранится в `team_members` таблице (Schema.TeamMembers, M007).
///
/// `removedAt` IS NULL = active member. Set при removal (Phase 5.3 flow).
///
/// `pubkeyHex` — X25519 32-byte public, hex-encoded (64 chars). Private
/// 32 байт никогда не попадают в DB — keystore-файл (5.1.D, contract §7).
///
/// Phase Track-5 S2 — `orgID` renamed → `workspaceID`. Backward-compat
/// `orgID` computed property + init overload retained until Task 12 cleanup.
public struct TeamMember: Sendable, Hashable {
    public let id: String
    public let workspaceID: String
    public let role: TeamMemberRole
    public let pubkeyHex: String
    public let displayName: String
    public let addedAt: Date
    public let removedAt: Date?

    public init(
        id: String,
        workspaceID: String,
        role: TeamMemberRole,
        pubkeyHex: String,
        displayName: String,
        addedAt: Date,
        removedAt: Date?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.role = role
        self.pubkeyHex = pubkeyHex
        self.displayName = displayName
        self.addedAt = addedAt
        self.removedAt = removedAt
    }

    /// Backward-compat init shim — deleted in Task 12. Forwards to primary.
    @available(*, deprecated, message: "Use `workspaceID:` parameter (Track 5 S2)")
    public init(
        id: String,
        orgID: String,
        role: TeamMemberRole,
        pubkeyHex: String,
        displayName: String,
        addedAt: Date,
        removedAt: Date?
    ) {
        self.init(
            id: id,
            workspaceID: orgID,
            role: role,
            pubkeyHex: pubkeyHex,
            displayName: displayName,
            addedAt: addedAt,
            removedAt: removedAt
        )
    }

    /// Backward-compat read accessor — deleted in Task 12.
    @available(*, deprecated, message: "Use `workspaceID` property (Track 5 S2)")
    public var orgID: String { workspaceID }
}
