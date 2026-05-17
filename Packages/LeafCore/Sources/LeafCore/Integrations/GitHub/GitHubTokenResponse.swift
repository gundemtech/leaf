//
//  GitHubTokenResponse.swift
//  LeafCore
//
//  Phase 4.3 — Codable DTOs для GitHub Device Flow и refresh responses.
//  GitHub возвращает либо form-encoded, либо JSON в зависимости от Accept header;
//  клиент всегда шлёт `Accept: application/json` → JSON shape.
//  `nonisolated` — DTO декодируются в URLSession callback context.
//

import Foundation

/// Success response для `POST /login/oauth/access_token`.
/// При `grant_type=urn:ietf:params:oauth:grant-type:device_code`:
///   - long-lived OAuth App (token expiration OFF): `expiresIn`/`refreshToken` отсутствуют.
///   - rotating OAuth App (token expiration ON): `expiresIn` ~28800 (8h),
///     `refreshToken` присутствует, `refreshTokenExpiresIn` ~15724800 (6 месяцев).
nonisolated public struct GitHubTokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let scope: String
    public let expiresIn: Int?
    public let refreshToken: String?
    public let refreshTokenExpiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
    }
}

/// Error response для `/login/oauth/access_token` (RFC 6749 §5.2 +
/// RFC 8628 §3.5 device-flow specific codes).
/// Codable с обоими `error` и `error_description`; UI показывает description.
///
/// Device flow codes (RFC 8628):
///   - `authorization_pending` — юзер ещё не авторизовал, продолжаем polling.
///   - `slow_down` — увеличить interval на 5s.
///   - `expired_token` — device_code истёк (>15 min), нужен restart.
///   - `access_denied` — юзер отклонил.
nonisolated public struct GitHubTokenError: Decodable, Sendable {
    public let error: String
    public let errorDescription: String?
    public let errorURI: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case errorURI = "error_uri"
    }
}

/// Response для `POST /login/device/code` — initial device code request.
nonisolated public struct GitHubDeviceCodeResponse: Decodable, Sendable {
    /// Long random string — отправляется на `/login/oauth/access_token` polling'ом.
    public let deviceCode: String
    /// Short human-readable code (e.g. "WDJB-MJHT") — юзер вводит на verification_uri.
    public let userCode: String
    /// URL куда юзер идёт, обычно `https://github.com/login/device`.
    public let verificationURI: String
    /// Полный URL с pre-filled user_code (если сервер поддерживает).
    public let verificationURIComplete: String?
    /// Время жизни device_code в секундах (GitHub: 900 = 15 min).
    public let expiresIn: Int
    /// Минимальный интервал polling'а в секундах (GitHub: 5).
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// `GET /user` viewer identity response. Минимальный subset полей.
nonisolated public struct GitHubViewerResponse: Decodable, Sendable {
    public let id: Int
    public let login: String
    public let nodeID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case nodeID = "node_id"
    }
}
