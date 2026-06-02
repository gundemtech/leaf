import Foundation

/// Phase 5.1.A — member role within the org. Stored as TEXT in team_members.role.
/// Contract §4: admin carries org/billing/invite permissions, WITHOUT
/// privileged read access (Share Controls invariant — admin is symmetric).
public enum TeamMemberRole: String, Codable, Sendable, CaseIterable {
    case admin
    case member
}
