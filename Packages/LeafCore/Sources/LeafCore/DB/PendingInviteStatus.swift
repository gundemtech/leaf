import Foundation

/// Phase 5.5.A — lifecycle status for `pending_invites` rows.
/// rawValue maps to TEXT column (lowercase). 5 cases:
/// - `pending` — admin POSTed invite to relay; awaiting invitee accept.
/// - `consumed` — relay returned 404 on Refresh; invitee fetched + accepted.
/// - `expired` — local clock past `expires_at_ms` without accept.
/// - `revoked` — admin called DELETE on relay (5.5.C surface).
/// - `failed` — relay rejected POST (network / 4xx) — retain row for diagnostics.
public enum PendingInviteStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case consumed
    case expired
    case revoked
    case failed
}
