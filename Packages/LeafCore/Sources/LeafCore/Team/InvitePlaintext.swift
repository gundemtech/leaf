import Foundation

/// JSON-encoded plaintext sealed inside `InviteBlob` (Phase 5.2.B).
///
/// Wire shape — decomposition spec §4.3 (snake_case keys). `teamKeyBase64`
/// carries raw 32B AES-256 team_key as base64 string (caller decodes at the boundary).
public struct InvitePlaintext: Sendable, Hashable, Codable {
    public let teamKeyBase64: String
    public let teamKeyID: String
    public let orgID: String
    public let orgName: String
    public let adminMemberID: String
    public let adminDisplayName: String
    public let issuedAtMs: Int64

    public init(teamKeyBase64: String,
                teamKeyID: String,
                orgID: String,
                orgName: String,
                adminMemberID: String,
                adminDisplayName: String,
                issuedAtMs: Int64) {
        self.teamKeyBase64 = teamKeyBase64
        self.teamKeyID = teamKeyID
        self.orgID = orgID
        self.orgName = orgName
        self.adminMemberID = adminMemberID
        self.adminDisplayName = adminDisplayName
        self.issuedAtMs = issuedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case teamKeyBase64 = "team_key"
        case teamKeyID = "team_key_id"
        case orgID = "org_id"
        case orgName = "org_name"
        case adminMemberID = "admin_member_id"
        case adminDisplayName = "admin_display_name"
        case issuedAtMs = "issued_at_ms"
    }
}
