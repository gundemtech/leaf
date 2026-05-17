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

// swiftlint:disable force_unwrapping
// Reason: compile-time-constant URL literals (`URL(string: "https://...")`) never
// fail to parse — `!` is a static guarantee, not a runtime risk.

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

    /// `GET /notifications?all=false&participating=false&per_page=50` — Phase 4.7.B-1.
    /// Inbox state pulse: только unread (`all=false`) + все subscriptions (`participating=false`
    /// чтобы включить team_mention / state_change / ci_activity, не только direct comments).
    /// Body / subject text НЕ extract'им (ADR-010) — только count + reason breakdown.
    public static let notifications = URL(string: "https://api.github.com/notifications")!

    /// `GET /search/issues?q=...&per_page=50` — Phase 4.7.B-2.
    /// Used для review queue (`review-requested:@me+is:open+is:pr`) и моих open PRs
    /// (`author:@me+is:open+is:pr`). ADR-010: title / body items НЕ читаем — только
    /// `repository_url` (parsed → "owner/repo") и total count.
    public static let searchIssues = URL(string: "https://api.github.com/search/issues")!

    /// `POST /graphql` — Phase 4.7.B-5. GraphQL endpoint для
    /// `viewer.contributionsCollection.contributionCalendar` (heatmap + today's count).
    /// REST API нет equivalent — public-events / private-events split не доступен,
    /// только GraphQL отдаёт unified contribution count со включёнными private repos
    /// (если юзер их `Profile → Settings → Contributions` enabled).
    public static let graphql = URL(string: "https://api.github.com/graphql")!

    /// Минимальный scope для work workflow integration.
    /// `repo` — обязателен для private events (без него feed возвращает только public, тихо).
    /// `read:user` — для GET /user identity fetch.
    @available(*, deprecated, message: "Use GitHubScopesService.requested() — replaced in D2 (scope bump)")
    public static let scopes: [String] = ["repo", "read:user"]

    /// Comma-separated form для отправки в `/login/device/code`.
    @available(
        *, deprecated, message: "Use GitHubOAuthEndpoints.requestedScopeParameter() — replaced in D2 (scope bump)"
    )
    public static var scopeParameter: String { scopes.joined(separator: " ") }

    /// Canonical scope parameter — union of required core + optional from GitHubScopesService.
    /// Space-separated form для отправки в `/login/device/code` (D2 scope bump).
    public static func requestedScopeParameter() -> String {
        GitHubScopesService.requested().joined(separator: " ")
    }

    /// DistributedNotification name, постится при connect/disconnect/refreshDenied.
    /// Слушают: ConnectionsSettings (UI re-render), GitHubCollector (Phase 4.3 reload).
    public static let integrationChangedNotificationName = "tech.gundem.leaf.github-integration-changed"

    /// UserDefaults suite/key для refresh denial flag. Cross-process: тот же
    /// suite (`tech.gundem.leaf`) что и Linear, отдельный provider-specific ключ.
    public static let userDefaultsSuite = "tech.gundem.leaf"
    public static let refreshDeniedFlagKey = "github.refreshDenied"
}
// swiftlint:enable force_unwrapping
