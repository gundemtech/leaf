import Foundation

/// Phase 5.1.B — long-term member identity + X25519 public key (contract §4, §7).
/// Stored in the `team_members` table (Schema.TeamMembers, M007).
///
/// `removedAt` IS NULL = active member. Set on removal (Phase 5.3 flow).
///
/// `pubkeyHex` — X25519 32-byte public, hex-encoded (64 chars). Private
/// 32 bytes never touch the DB — keystore file (5.1.D, contract §7).
///
/// Phase Track-5 S2 — `orgID` renamed → `workspaceID` (M019). Back-compat
/// `orgID` computed property + init overload were deleted in Task 12 cleanup;
/// all call sites must provide `workspaceID` explicitly.
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

}
