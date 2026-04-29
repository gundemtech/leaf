//
//  SlackTokenResponse.swift
//  LeafCore
//
//  Phase 4.4 — Codable DTOs для Slack `oauth.v2.access` (initial code exchange
//  + grant_type=refresh_token). Slack возвращает совместимую shape для обоих
//  grants, поэтому один DTO покрывает оба case'а.
//
//  User-token берётся из `authed_user.access_token` (xoxp-). Top-level
//  `access_token` приходит ТОЛЬКО при bot scopes (мы их не запрашиваем).
//
//  `nonisolated` — DTO декодируются JSONDecoder в URLSession callback context.
//

import Foundation

/// `POST /api/oauth.v2.access` response.
/// Slack использует `ok: Bool` flag в теле — на error'е ok=false и `error`
/// заполнено (RFC 6749 deviation; HTTP-код может быть 200 даже для ошибки).
/// Caller должен проверять `ok` перед чтением остальных полей.
public nonisolated struct SlackOAuthV2Response: Decodable, Sendable {
    public let ok: Bool

    /// Top-level access_token приходит ТОЛЬКО при bot scopes (мы их не запрашиваем).
    /// User-token берётся из `authedUser.accessToken`.
    public let accessToken: String?
    public let tokenType: String?
    public let scope: String?
    public let team: SlackTeam?
    public let authedUser: SlackAuthedUser?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
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
        /// xoxp-... — это наш user token.
        public let accessToken: String?
        public let tokenType: String?
        /// Present iff token rotation enabled на app side (recommended).
        public let refreshToken: String?
        /// Seconds; nil если non-rotating (long-lived xoxp- token).
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
