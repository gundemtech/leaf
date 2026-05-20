import Foundation

/// M027 — Invite token value type. Wraps a single `invite_tokens` row.
/// Pure identifier with no crypto material — the workspace teamKey is sealed
/// at admin's `Approve` moment on `join_requests.encrypted_team_key` (S3 envelope
/// v=1, see `JoinRequestService.approve`).
public struct InviteToken: Equatable, Sendable, Codable {
    public let code: String
    public let workspaceID: String
    public let createdByPubkeyHex: String
    public let label: String?
    /// TTL in seconds chosen at generate time. 0 sentinel = «Never expires»
    /// (in which case `expiresAt` is nil).
    public let ttlSeconds: Int
    public let expiresAt: Date?
    /// nil = unlimited; 1 = single-use; N > 0 = cap.
    public let maxUses: Int?
    public let usedCount: Int
    public let deletedAt: Date?
    public let createdAt: Date

    public init(
        code: String,
        workspaceID: String,
        createdByPubkeyHex: String,
        label: String?,
        ttlSeconds: Int,
        expiresAt: Date?,
        maxUses: Int?,
        usedCount: Int,
        deletedAt: Date?,
        createdAt: Date
    ) {
        self.code = code
        self.workspaceID = workspaceID
        self.createdByPubkeyHex = createdByPubkeyHex
        self.label = label
        self.ttlSeconds = ttlSeconds
        self.expiresAt = expiresAt
        self.maxUses = maxUses
        self.usedCount = usedCount
        self.deletedAt = deletedAt
        self.createdAt = createdAt
    }

    /// `true` iff token is currently active (not deleted, not expired, not exhausted).
    /// Used by Active-tokens UI to filter the visible list.
    public func isActive(at now: Date = Date()) -> Bool {
        if deletedAt != nil { return false }
        if let expires = expiresAt, expires <= now { return false }
        if let max = maxUses, usedCount >= max { return false }
        return true
    }

    /// Human-readable label fallback when admin didn't provide one. Format:
    /// `Untitled token #ABCD` (first 4 chars of code body after `LEAF-`).
    public var displayLabel: String {
        if let l = label, !l.isEmpty { return l }
        let prefix = code.dropFirst("LEAF-".count).prefix(4)
        return "Untitled token #\(prefix)"
    }
}
