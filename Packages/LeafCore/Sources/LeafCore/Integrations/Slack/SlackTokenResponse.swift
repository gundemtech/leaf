//
//  SlackTokenResponse.swift
//  LeafCore
//
//  Phase 4.4 — Codable DTOs для Slack `oauth.v2.access` (initial code exchange
//  + grant_type=refresh_token). Slack возвращает совместимую shape для обоих
//  grants, поэтому один DTO покрывает оба case'а.
//
//  Initial code exchange: user-token живёт в `authed_user.access_token` (xoxp-);
//  top-level `access_token` приходит ТОЛЬКО при bot scopes (мы их не запрашиваем).
//
//  `grant_type=refresh_token` (token rotation): новый user-token приходит на
//  TOP LEVEL — `access_token` (xoxe.xoxp-), `refresh_token`, `expires_in`.
//  `authed_user` в refresh-ответе содержит только `id`. Verified против
//  https://api.slack.com/authentication/token-rotation.
//
//  `nonisolated` — DTO декодируются JSONDecoder в URLSession callback context.
//

import Foundation

/// `POST /api/oauth.v2.access` response.
/// Slack использует `ok: Bool` flag в теле — на error'е ok=false и `error`
/// заполнено (RFC 6749 deviation; HTTP-код может быть 200 даже для ошибки).
/// Caller должен проверять `ok` перед чтением остальных полей.
nonisolated public struct SlackOAuthV2Response: Decodable, Sendable {
    public let ok: Bool

    /// Initial code exchange: bot-token (мы не запрашиваем) → nil для user-only flow.
    /// Refresh-flow: новый user-token (xoxe.xoxp-).
    public let accessToken: String?
    public let tokenType: String?
    public let scope: String?
    /// Refresh-flow only: новый refresh_token (rotated). Initial exchange кладёт
    /// refresh_token в `authedUser.refreshToken`.
    public let refreshToken: String?
    /// Refresh-flow only: TTL нового access_token в секундах.
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

    nonisolated public struct SlackTeam: Decodable, Sendable {
        public let id: String
        public let name: String
    }

    nonisolated public struct SlackAuthedUser: Decodable, Sendable {
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
