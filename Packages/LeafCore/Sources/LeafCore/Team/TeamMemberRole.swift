import Foundation

/// Phase 5.1.A — роль member в org. Stored as TEXT в team_members.role.
/// Contract §4: admin несёт org/billing/invite permissions, БЕЗ
/// privileged read access (Share Controls invariant — admin симметричен).
public enum TeamMemberRole: String, Codable, Sendable, CaseIterable {
    case admin
    case member
}
