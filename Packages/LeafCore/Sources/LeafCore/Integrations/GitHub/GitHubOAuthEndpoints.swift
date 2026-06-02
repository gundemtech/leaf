//
//  GitHubOAuthEndpoints.swift
//  LeafCore
//
//  Phase 4.3 — endpoint URLs + scopes for GitHub Device Flow (RFC 8628).
//  GitHub OAuth Apps don't support PKCE, and storing client_secret in a public
//  binary is a moat leak. Device Flow uses the public client model: only
//  client_id, the user enters user_code on github.com/login/device.
//
//  Verified against https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow 2026-04-28.
//

import Foundation

public enum GitHubOAuthEndpoints {
    /// `POST /login/device/code` — initial step, returns device_code + user_code +
    /// verification_uri + interval. The UI renders user_code and opens verification_uri.
    public static let deviceAuthorize = URL(string: "https://github.com/login/device/code")!

    /// `POST /login/oauth/access_token` — polling endpoint. Used both for the
    /// device-code grant (with `grant_type=urn:ietf:params:oauth:grant-type:device_code`),
    /// and for refresh (`grant_type=refresh_token`) if token expiration is enabled.
    public static let token = URL(string: "https://github.com/login/oauth/access_token")!

    /// `GET /user` — after the exchange, reads viewer identity (`login`, `id`, `node_id`).
    /// Login is used as the workspaceID (`github:<login>`) and as a path segment for events.
    public static let viewer = URL(string: "https://api.github.com/user")!

    /// `GET <eventsBase><login>/events` — REST events feed. Returns the last 90
    /// days of events across all repos where the viewer is a contributor (including private with
    /// `repo` scope). Cursor — `created_at` of the freshest event in the batch, dedup on
    /// the Swift side via an event `id` set.
    public static let eventsBase = URL(string: "https://api.github.com/users/")!

    /// `GET /notifications?all=false&participating=false&per_page=50` — Phase 4.7.B-1.
    /// Inbox state pulse: only unread (`all=false`) + all subscriptions (`participating=false`
    /// to include team_mention / state_change / ci_activity, not just direct comments).
    /// Body / subject text is NOT extracted (ADR-010) — only count + reason breakdown.
    public static let notifications = URL(string: "https://api.github.com/notifications")!

    /// `GET /search/issues?q=...&per_page=50` — Phase 4.7.B-2.
    /// Used for the review queue (`review-requested:@me+is:open+is:pr`) and my open PRs
    /// (`author:@me+is:open+is:pr`). ADR-010: we don't read title / body of items — only
    /// `repository_url` (parsed → "owner/repo") and the total count.
    public static let searchIssues = URL(string: "https://api.github.com/search/issues")!

    /// `POST /graphql` — Phase 4.7.B-5. GraphQL endpoint for
    /// `viewer.contributionsCollection.contributionCalendar` (heatmap + today's count).
    /// The REST API has no equivalent — the public-events / private-events split isn't available,
    /// only GraphQL returns a unified contribution count with private repos included
    /// (if the user has enabled them in `Profile → Settings → Contributions`).
    public static let graphql = URL(string: "https://api.github.com/graphql")!

    /// Minimal scope for work-workflow integration.
    /// `repo` — required for private events (without it the feed returns only public, silently).
    /// `read:user` — for the GET /user identity fetch.
    @available(*, deprecated, message: "Use GitHubScopesService.requested() — replaced in D2 (scope bump)")
    public static let scopes: [String] = ["repo", "read:user"]

    /// Comma-separated form for sending to `/login/device/code`.
    @available(*, deprecated, message: "Use GitHubOAuthEndpoints.requestedScopeParameter() — replaced in D2 (scope bump)")
    public static var scopeParameter: String { scopes.joined(separator: " ") }

    /// Canonical scope parameter — union of required core + optional from GitHubScopesService.
    /// Space-separated form for sending to `/login/device/code` (D2 scope bump).
    public static func requestedScopeParameter() -> String {
        GitHubScopesService.requested().joined(separator: " ")
    }

    /// DistributedNotification name, posted on connect/disconnect/refreshDenied.
    /// Listeners: ConnectionsSettings (UI re-render), GitHubCollector (Phase 4.3 reload).
    public static let integrationChangedNotificationName = "tech.gundem.leaf.github-integration-changed"

    /// UserDefaults suite/key for the refresh denial flag. Cross-process: the same
    /// suite (`tech.gundem.leaf`) as Linear, with a separate provider-specific key.
    public static let userDefaultsSuite = "tech.gundem.leaf"
    public static let refreshDeniedFlagKey = "github.refreshDenied"
}
