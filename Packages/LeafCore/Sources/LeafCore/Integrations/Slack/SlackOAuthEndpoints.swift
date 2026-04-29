//
//  SlackOAuthEndpoints.swift
//  LeafCore
//
//  Phase 4.4 — endpoint URLs + scopes для Slack OAuth (PKCE loopback).
//  Slack OAuth Apps поддерживают PKCE с 2026-03-30, redirect URI на 127.0.0.1
//  допустим per RFC 8252 (loopback). User token (xoxp-) only — bot scopes
//  desktop redirect не разрешает, и нам не нужен Slack-app персонаж в
//  чужом workspace.
//
//  Verified против https://api.slack.com/authentication/oauth-v2 2026-04-29.
//

import Foundation

public enum SlackOAuthEndpoints {
    /// Authorize URL — browser flow начинается здесь.
    public static let authorize = URL(string: "https://slack.com/oauth/v2/authorize")!
    /// Token endpoint — POST для initial code exchange и для grant_type=refresh_token
    /// (если token rotation enabled на app side).
    public static let token = URL(string: "https://slack.com/api/oauth.v2.access")!
    /// `users.profile.get` — без `?user=` default'ит на authed user. Используется
    /// в SlackCollector tick для huddle_state detection.
    public static let usersProfileGet = URL(string: "https://slack.com/api/users.profile.get")!
    /// `search.messages` — query: `from:me after:<DATE>`. Используется в
    /// SlackCollector tick для message activity counts.
    public static let searchMessages = URL(string: "https://slack.com/api/search.messages")!

    /// Loopback redirect URI. Slack требует exact-match (port обязателен в
    /// app config). Port 47824 — на единицу больше Linear'овского 47823, чтобы
    /// избежать coincidental collision listener'а (flow'ы не пересекаются по
    /// времени — но cleaner).
    /// При изменении порта обнови redirect URI в Slack OAuth app config.
    public static let redirectHost = "127.0.0.1"
    public static let redirectPort: UInt16 = 47824
    public static let redirectPath = "/callback"
    public static var redirectURI: String { "http://\(redirectHost):\(redirectPort)\(redirectPath)" }

    /// User scopes only — bot scopes desktop redirect не разрешает.
    /// ВАЖНО: для authorize URL это значение идёт в `user_scope` query param,
    /// НЕ в `scope` — `scope` в Slack v2 это bot-token scopes; user-token scopes
    /// идут отдельным параметром.
    public static let userScopes = "users:read,users.profile:read,search:read"

    /// DistributedNotification name, постится при connect/disconnect/refreshDenied.
    /// Слушают: ConnectionsSettings (UI re-render), SlackCollector (Phase 4.4 reload).
    public static let integrationChangedNotificationName = "tech.gundem.leaf.slack-integration-changed"

    /// UserDefaults suite/key для refresh denial flag. Cross-process: тот же
    /// suite (`tech.gundem.leaf`) что и Linear/GitHub, отдельный provider-specific ключ.
    public static let userDefaultsSuite = "tech.gundem.leaf"
    public static let refreshDeniedFlagKey = "slack.refreshDenied"
}
