import Foundation

/// Phase 5.5.A — admin-side row for `pending_invites` table.
/// Plain Sendable struct (no GRDB Record protocol) — CRUD lives in `PendingInvitesStore`
/// mirroring `PresenceStateWriter` pattern.
public struct PendingInvite: Sendable, Equatable {
    public let token: String
    public let otp: String
    public let inviteePubkeyHex: String
    public let inviteeDisplayNameHint: String?
    public let createdAtMs: Int64
    public let expiresAtMs: Int64
    public let status: PendingInviteStatus
    public let lastPolledAtMs: Int64?

    public init(
        token: String,
        otp: String,
        inviteePubkeyHex: String,
        inviteeDisplayNameHint: String? = nil,
        createdAtMs: Int64,
        expiresAtMs: Int64,
        status: PendingInviteStatus = .pending,
        lastPolledAtMs: Int64? = nil
    ) {
        self.token = token
        self.otp = otp
        self.inviteePubkeyHex = inviteePubkeyHex
        self.inviteeDisplayNameHint = inviteeDisplayNameHint
        self.createdAtMs = createdAtMs
        self.expiresAtMs = expiresAtMs
        self.status = status
        self.lastPolledAtMs = lastPolledAtMs
    }
}
