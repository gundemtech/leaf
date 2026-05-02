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
    /// `conversations.history` — per-channel message fetch с populated reactions[].
    /// Phase 4.6.A.3 — single source of truth для reactions aggregate (search.messages
    /// response не включает reactions field by design — different schema от
    /// conversations.history). Вызывается per unique channel_id обнаруженный в
    /// search.messages response, filtered `user == self_user_id` client-side.
    public static let conversationsHistory = URL(string: "https://slack.com/api/conversations.history")!
    /// `users.getPresence` — Tier 3 (50+ req/min). Per-user presence ("active"|"away").
    /// Phase 4.7.B-9 — emits per-tick `slack_presence_state` pulse (mirror к GitHub
    /// `github_notifications_pulse`). Self-only call (вызываем для авторизованного юзера).
    public static let usersGetPresence = URL(string: "https://slack.com/api/users.getPresence")!
    /// `dnd.info` — Tier 3. Per-user DND state (current dnd + scheduled DND window
    /// + user-set snooze). Phase 4.7.B-10 — emits per-tick `slack_dnd_state` pulse.
    /// Self-only (`?user=<authed user>`); требует scope `dnd:read`.
    public static let dndInfo = URL(string: "https://slack.com/api/dnd.info")!

    /// Public redirect URI для Slack OAuth `/oauth/v2/authorize` и token exchange.
    /// Slack distributed-app distribution требует HTTPS на redirect URI; loopback
    /// `http://127.0.0.1:…` физически не может иметь TLS-серт. Поэтому здесь
    /// публичный HTTPS endpoint Cloudflare Worker'а, который 302-редиректит обратно
    /// на loopback listener (см. ниже). Worker stateless, не видит токенов.
    /// Repo: gundemtech/leaf-relay (приватный).
    /// При изменении этого URI обнови redirect URI в Slack OAuth app config.
    public static let redirectURI = "https://oauth.gundem.tech/slack/callback"

    /// Loopback listener — куда Cloudflare Worker 302-редиректит после Slack
    /// approval. SlackOAuthService биндит NWListener на этот port + ловит auth
    /// code. Port 47824 — на единицу больше Linear'овского 47823, cleaner separation.
    public static let loopbackHost = "127.0.0.1"
    public static let loopbackPort: UInt16 = 47824
    public static let loopbackPath = "/callback"

    /// User scopes only — bot scopes desktop redirect не разрешает.
    /// ВАЖНО: для authorize URL это значение идёт в `user_scope` query param,
    /// НЕ в `scope` — `scope` в Slack v2 это bot-token scopes; user-token scopes
    /// идут отдельным параметром.
    /// Phase 4.6.A.3 — added `*:history` scopes for `conversations.history`
    /// endpoint (reactions aggregate). Adding scopes требует full OAuth re-consent
    /// (юзер проходит Disconnect → Connect один раз), backward-compat broken
    /// для existing alpha.6 tokens.
    /// Phase 4.7.B-10 — added `dnd:read` for `dnd.info` (slack_dnd_state pulse).
    /// Same re-consent caveat: new scope требует Disconnect → Connect.
    public static let userScopes = "users:read,users.profile:read,search:read,channels:history,groups:history,im:history,mpim:history,dnd:read"

    /// DistributedNotification name, постится при connect/disconnect/refreshDenied.
    /// Слушают: ConnectionsSettings (UI re-render), SlackCollector (Phase 4.4 reload).
    public static let integrationChangedNotificationName = "tech.gundem.leaf.slack-integration-changed"

    /// UserDefaults suite/key для refresh denial flag. Cross-process: тот же
    /// suite (`tech.gundem.leaf`) что и Linear/GitHub, отдельный provider-specific ключ.
    public static let userDefaultsSuite = "tech.gundem.leaf"
    public static let refreshDeniedFlagKey = "slack.refreshDenied"
}
