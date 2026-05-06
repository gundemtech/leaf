import Foundation

/// Phase 5.2.D — admin-side result of `InviteService.generateInvite`. Carries the
/// `token` + `otp` pair the admin transmits OOB to the invitee (Slack/Telegram),
/// plus `expiresAtMs` for UI countdown and `inviteePubkeyHex` for back-reference
/// ("this invite is for invitee X"). `Hashable` so UI sheet state can use it as
/// associated value of an `Equatable` enum.
public struct InviteOutbound: Sendable, Hashable {
    public let token: String
    public let otp: String
    public let expiresAtMs: Int64
    public let inviteePubkeyHex: String

    public init(token: String, otp: String, expiresAtMs: Int64, inviteePubkeyHex: String) {
        self.token = token
        self.otp = otp
        self.expiresAtMs = expiresAtMs
        self.inviteePubkeyHex = inviteePubkeyHex
    }
}
