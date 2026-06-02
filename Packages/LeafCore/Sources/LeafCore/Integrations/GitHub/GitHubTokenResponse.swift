//
//  GitHubTokenResponse.swift
//  LeafCore
//
//  Phase 4.3 — Codable DTOs for GitHub Device Flow and refresh responses.
//  GitHub returns either form-encoded or JSON depending on the Accept header;
//  the client always sends `Accept: application/json` → JSON shape.
//  `nonisolated` — DTOs are decoded in the URLSession callback context.
//

import Foundation

/// Success response for `POST /login/oauth/access_token`.
/// With `grant_type=urn:ietf:params:oauth:grant-type:device_code`:
///   - long-lived OAuth App (token expiration OFF): `expiresIn`/`refreshToken` are absent.
///   - rotating OAuth App (token expiration ON): `expiresIn` ~28800 (8h),
///     `refreshToken` is present, `refreshTokenExpiresIn` ~15724800 (6 months).
public nonisolated struct GitHubTokenResponse: Decodable, Sendable {
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

/// Error response for `/login/oauth/access_token` (RFC 6749 §5.2 +
/// RFC 8628 §3.5 device-flow specific codes).
/// Codable with both `error` and `error_description`; the UI shows the description.
///
/// Device flow codes (RFC 8628):
///   - `authorization_pending` — the user has not authorized yet, keep polling.
///   - `slow_down` — increase the interval by 5s.
///   - `expired_token` — device_code expired (>15 min), restart needed.
///   - `access_denied` — the user declined.
public nonisolated struct GitHubTokenError: Decodable, Sendable {
    public let error: String
    public let errorDescription: String?
    public let errorURI: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case errorURI = "error_uri"
    }
}

/// Response for `POST /login/device/code` — initial device code request.
public nonisolated struct GitHubDeviceCodeResponse: Decodable, Sendable {
    /// Long random string — sent to `/login/oauth/access_token` while polling.
    public let deviceCode: String
    /// Short human-readable code (e.g. "WDJB-MJHT") — the user enters it on verification_uri.
    public let userCode: String
    /// URL the user goes to, usually `https://github.com/login/device`.
    public let verificationURI: String
    /// Full URL with a pre-filled user_code (if the server supports it).
    public let verificationURIComplete: String?
    /// device_code lifetime in seconds (GitHub: 900 = 15 min).
    public let expiresIn: Int
    /// Minimum polling interval in seconds (GitHub: 5).
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

/// `GET /user` viewer identity response. Minimal subset of fields.
public nonisolated struct GitHubViewerResponse: Decodable, Sendable {
    public let id: Int
    public let login: String
    public let nodeID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case nodeID = "node_id"
    }
}
