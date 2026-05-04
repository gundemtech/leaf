import Foundation

/// Phase 5.1.B — long-term member identity + X25519 public key (contract §4, §7).
/// Хранится в `team_members` таблице (Schema.TeamMembers, M007).
///
/// `removedAt` IS NULL = active member. Set при removal (Phase 5.3 flow);
/// в 5.1.B mutator-helper нет — вызовется из 5.3 после rotation policy zafix'а.
///
/// `pubkeyHex` — X25519 32-byte public, hex-encoded (64 chars). Private
/// 32 байт никогда не попадают в DB — keystore-файл (5.1.D, contract §7).
public struct TeamMember: Sendable, Hashable {
    public let id: String
    public let orgID: String
    public let role: TeamMemberRole
    public let pubkeyHex: String
    public let displayName: String
    public let addedAt: Date
    public let removedAt: Date?

    public init(
        id: String,
        orgID: String,
        role: TeamMemberRole,
        pubkeyHex: String,
        displayName: String,
        addedAt: Date,
        removedAt: Date?
    ) {
        self.id = id
        self.orgID = orgID
        self.role = role
        self.pubkeyHex = pubkeyHex
        self.displayName = displayName
        self.addedAt = addedAt
        self.removedAt = removedAt
    }
}
