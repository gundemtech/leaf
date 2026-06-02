//
//  SlackTokenResponse.swift
//  LeafCore
//
//  Phase 4.4 — Codable DTOs for Slack `oauth.v2.access` (initial code exchange
//  + grant_type=refresh_token). Slack returns a compatible shape for both
//  grants, so a single DTO covers both cases.
//
//  Initial code exchange: the user-token lives in `authed_user.access_token` (xoxp-);
//  the top-level `access_token` comes back ONLY with bot scopes (which we don't request).
//
//  `grant_type=refresh_token` (token rotation): the new user-token arrives at the
//  TOP LEVEL — `access_token` (xoxe.xoxp-), `refresh_token`, `expires_in`.
//  `authed_user` in the refresh response contains only `id`. Verified against
//  https://api.slack.com/authentication/token-rotation.
//
//  `nonisolated` — the DTOs are decoded by JSONDecoder in the URLSession callback context.
//

import Foundation

/// `POST /api/oauth.v2.access` response.
/// Slack uses an `ok: Bool` flag in the body — on error ok=false and `error`
/// is populated (RFC 6749 deviation; the HTTP code may be 200 even for an error).
/// The caller must check `ok` before reading the remaining fields.
public nonisolated struct SlackOAuthV2Response: Decodable, Sendable {
    public let ok: Bool

    /// Initial code exchange: bot-token (which we don't request) → nil for the user-only flow.
    /// Refresh flow: the new user-token (xoxe.xoxp-).
    public let accessToken: String?
    public let tokenType: String?
    public let scope: String?
    /// Refresh flow only: the new refresh_token (rotated). The initial exchange puts
    /// refresh_token in `authedUser.refreshToken`.
    public let refreshToken: String?
    /// Refresh flow only: TTL of the new access_token in seconds.
    public let expiresIn: Int?
    public let team: SlackTeam?
    public let authedUser: SlackAuthedUser?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case team
        case authedUser = "authed_user"
        case error
    }

    public nonisolated struct SlackTeam: Decodable, Sendable {
        public let id: String
        public let name: String
    }

    public nonisolated struct SlackAuthedUser: Decodable, Sendable {
        /// Slack user id, e.g. "U01ABC".
        public let id: String
        /// Granted user scopes (comma-separated).
        public let scope: String?
        /// xoxp-... — this is our user token.
        public let accessToken: String?
        public let tokenType: String?
        /// Present iff token rotation is enabled on the app side (recommended).
        public let refreshToken: String?
        /// Seconds; nil if non-rotating (long-lived xoxp- token).
        public let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case scope
            case accessToken = "access_token"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }
}
