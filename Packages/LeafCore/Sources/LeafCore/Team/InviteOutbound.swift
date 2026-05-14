import Foundation

/// Track 5 / S3 — admin-side result of `InviteService.generateInvite`. Carries the
/// composed Track 5 §12 magic-link URL `leaf://invite/<22>?w=&a=[#<otp>]` plus
/// `token` (22-char base64url-uuid for audit lookup), optional `otp` (only when
/// admin toggled `Require OTP`), `expiresAtMs` for UI countdown, and
/// `inviteePubkeyHex` for back-reference.
public struct InviteOutbound: Sendable, Hashable {
    public let token: String         // 22-char base64url-uuid
    public let url: URL              // leaf://invite/<token>?w=...&a=...[#<otp>]
    public let otp: String?
    public let expiresAtMs: Int64
    public let inviteePubkeyHex: String

    public init(token: String, url: URL, otp: String?, expiresAtMs: Int64, inviteePubkeyHex: String) {
        self.token = token
        self.url = url
        self.otp = otp
        self.expiresAtMs = expiresAtMs
        self.inviteePubkeyHex = inviteePubkeyHex
    }
}
