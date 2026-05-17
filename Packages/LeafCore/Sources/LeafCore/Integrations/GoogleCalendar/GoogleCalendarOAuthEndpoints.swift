//
//  GoogleCalendarOAuthEndpoints.swift
//  LeafCore
//
//  Track-6 P4 — Google Identity Platform OAuth 2.0 endpoints + PKCE authorize URL builder.
//  Mirrors LinearOAuthEndpoints pattern; token exchange shipped в Task 9.
//
//  WHY split this out: cross-binary access (Agent collector + main app OAuthService).
//  Constants pinned per Google Identity docs (verified 2026-05-16):
//    https://developers.google.com/identity/protocols/oauth2/native-app
//

import Foundation

public struct GoogleCalendarOAuthEndpoints {
    // OAuth 2.0 endpoints (Google Identity Platform).
    public static let authorizationHost = "accounts.google.com"
    public static let authorizationPath = "/o/oauth2/v2/auth"
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    // Scope: see Stage 0 OQ-1 — calendar.readonly (single broad scope).
    // Не calendar.events.readonly (более узкий, но не даёт calendarList.list).
    public static let scope = "https://www.googleapis.com/auth/calendar.readonly"

    // Loopback redirect — ephemeral port (per spec §6.9, distinct from Linear=47823
    // fixed / Slack=47824 fixed). Google разрешает variable port в loopback redirect
    // (RFC 8252 compliant), unlike Linear которые требуют exact-match port. Caller
    // passes the port assigned by NWListener.
    public static let redirectHost = "127.0.0.1"
    public static let redirectPath = "/callback"

    // Info.plist key names — values plumbed at build time from .env per spec §7.6.
    // Никогда не hardcode client_id/client_secret в source — moat per CLAUDE.md.
    public static let infoPlistClientIDKey = "LeafGoogleCalendarOAuthClientID"
    public static let infoPlistClientSecretKey = "LeafGoogleCalendarOAuthClientSecret"

    /// `DistributedNotificationCenter` channel name posted by the OAuthService
    /// (main app) after connect / disconnect so the Agent's collector tick can
    /// pick up the new credential row without restart. Mirrors
    /// `LinearOAuthEndpoints.integrationChangedNotificationName`.
    public static let integrationChangedNotificationName = "tech.gundem.leaf.google-calendar-integration-changed"

    /// Build the authorization URL with PKCE + state + ephemeral redirect port.
    /// Per spec §7.1: `access_type=offline` + `prompt=consent` to receive `refresh_token`
    /// on first launch; `include_granted_scopes=true` to allow incremental authorization
    /// в v1.1 без потери этого grant.
    public static func authorizeURL(
        clientID: String,
        challenge: String,
        state: String,
        port: UInt16
    ) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = authorizationHost
        components.path = authorizationPath
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: "http://\(redirectHost):\(port)\(redirectPath)"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
        ]
        return components.url!
    }
}
