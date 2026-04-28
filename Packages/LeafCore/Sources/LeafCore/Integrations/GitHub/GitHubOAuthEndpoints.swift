//
//  GitHubOAuthEndpoints.swift
//  LeafCore
//
//  Phase 4.3 — endpoint URLs + scopes для GitHub Device Flow (RFC 8628).
//  GitHub OAuth Apps не поддерживают PKCE и хранение client_secret в публичном
//  binary — утечка moat. Device Flow использует public client model: только
//  client_id, юзер вводит user_code на github.com/login/device.
//
//  Verified против https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow 2026-04-28.
//

import Foundation

public enum GitHubOAuthEndpoints {
    /// `POST /login/device/code` — initial step, возвращает device_code + user_code +
    /// verification_uri + interval. UI рендерит user_code и открывает verification_uri.
    public static let deviceAuthorize = URL(string: "https://github.com/login/device/code")!

    /// `POST /login/oauth/access_token` — polling endpoint. Используется и для
    /// device-code grant'а (с `grant_type=urn:ietf:params:oauth:grant-type:device_code`),
    /// и для refresh (`grant_type=refresh_token`) если включён token expiration.
    public static let token = URL(string: "https://github.com/login/oauth/access_token")!

    /// `GET /user` — после exchange'а, читает viewer identity (`login`, `id`, `node_id`).
    /// Login используется как workspaceID (`github:<login>`) и path-сегмент для events.
    public static let viewer = URL(string: "https://api.github.com/user")!

    /// `GET <eventsBase><login>/events` — REST events feed. Возвращает последние 90
    /// дней событий across all repos где viewer contributor (включая private при
    /// `repo` scope). Cursor — `created_at` свежайшего event'а в batch'е, dedup на
    /// Swift-side через event `id` set.
    public static let eventsBase = URL(string: "https://api.github.com/users/")!

    /// Минимальный scope для work workflow integration.
    /// `repo` — обязателен для private events (без него feed возвращает только public, тихо).
    /// `read:user` — для GET /user identity fetch.
    public static let scopes: [String] = ["repo", "read:user"]

    /// Comma-separated form для отправки в `/login/device/code`.
    public static var scopeParameter: String { scopes.joined(separator: " ") }

    /// DistributedNotification name, постится при connect/disconnect/refreshDenied.
    /// Слушают: ConnectionsSettings (UI re-render), GitHubCollector (Phase 4.3 reload).
    public static let integrationChangedNotificationName = "tech.gundem.leaf.github-integration-changed"

    /// UserDefaults suite/key для refresh denial flag. Cross-process: тот же
    /// suite (`tech.gundem.leaf`) что и Linear, отдельный provider-specific ключ.
    public static let userDefaultsSuite = "tech.gundem.leaf"
    public static let refreshDeniedFlagKey = "github.refreshDenied"
}
