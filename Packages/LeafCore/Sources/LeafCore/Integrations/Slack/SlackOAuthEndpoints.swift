//
//  SlackOAuthEndpoints.swift
//  LeafCore
//
//  Phase 4.4 — endpoint URLs + scopes for Slack OAuth (PKCE loopback).
//  Slack OAuth Apps support PKCE since 2026-03-30, redirect URI on 127.0.0.1
//  allowed per RFC 8252 (loopback). User token (xoxp-) only — desktop redirect
//  does not allow bot scopes, and we don't need a Slack-app persona in
//  someone else's workspace.
//
//  Verified against https://api.slack.com/authentication/oauth-v2 2026-04-29.
//

import Foundation

public enum SlackOAuthEndpoints {
    /// Authorize URL — browser flow starts here.
    public static let authorize = URL(string: "https://slack.com/oauth/v2/authorize")!
    /// Token endpoint — POST for initial code exchange and for grant_type=refresh_token
    /// (if token rotation is enabled on the app side).
    public static let token = URL(string: "https://slack.com/api/oauth.v2.access")!
    /// `users.profile.get` — without `?user=` it defaults to the authed user. Used
    /// in the SlackCollector tick for huddle_state detection.
    public static let usersProfileGet = URL(string: "https://slack.com/api/users.profile.get")!
    /// `search.messages` — query: `from:me after:<DATE>`. Used in the
    /// SlackCollector tick for message activity counts.
    public static let searchMessages = URL(string: "https://slack.com/api/search.messages")!
    /// `conversations.history` — per-channel message fetch with populated reactions[].
    /// Phase 4.6.A.3 — single source of truth for the reactions aggregate (the
    /// search.messages response does not include the reactions field by design —
    /// different schema from conversations.history). Called per unique channel_id
    /// discovered in the search.messages response, filtered `user == self_user_id` client-side.
    public static let conversationsHistory = URL(string: "https://slack.com/api/conversations.history")!
    /// `conversations.list` — Tier 2 (~20 RPM). Viewer's accessible channels +
    /// metadata. Track 5 / S6 — used by `SlackChannelsReader` for the cross-post channel
    /// picker UI. Query `?types=public_channel,private_channel&exclude_archived=true`.
    /// Required user-token scopes `channels:read`, `groups:read` already in `requiredCore`.
    public static let conversationsList = URL(string: "https://slack.com/api/conversations.list")!
    /// `users.getPresence` — Tier 3 (50+ req/min). Per-user presence ("active"|"away").
    /// Phase 4.7.B-9 — emits per-tick `slack_presence_state` pulse (mirror of GitHub
    /// `gh_notifications_pulse`). Self-only call (made for the authorized user).
    public static let usersGetPresence = URL(string: "https://slack.com/api/users.getPresence")!
    /// `dnd.info` — Tier 3. Per-user DND state (current dnd + scheduled DND window
    /// + user-set snooze). Phase 4.7.B-10 — emits per-tick `slack_dnd_state` pulse.
    /// Self-only (`?user=<authed user>`); requires scope `dnd:read`.
    public static let dndInfo = URL(string: "https://slack.com/api/dnd.info")!
    /// `search.files` — Tier 2. Query `from:me after:<DATE>`. Phase 4.7.B-12 —
    /// emits per-tick `slack_file_uploaded_aggregate` (count + mime-type buckets).
    /// ADR-010: the provider extracts ONLY `file.mimetype`; filenames / previews /
    /// permalinks are ignored during parsing. Requires scope `files:read`.
    public static let searchFiles = URL(string: "https://slack.com/api/search.files")!
    /// `conversations.replies` — Tier 3. Thread fan-out for Track-1 D1.
    /// Query `?channel=<id>&ts=<threadTs>&oldest=<cursor>&limit=N`.
    /// Provider filters replies where `user == ownerUserID` OR thread parent
    /// authored by owner. ADR-010: text captured on-device only, never relayed.
    /// Requires scope `channels:history`, `groups:history`, `im:history`, `mpim:history`
    /// (same scopes as conversations.history, already in userScopes since Phase 4.6.A.3).
    public static let conversationsReplies = URL(string: "https://slack.com/api/conversations.replies")!

    /// Public redirect URI for Slack OAuth `/oauth/v2/authorize` and token exchange.
    /// Slack distributed-app distribution requires HTTPS on the redirect URI; the
    /// loopback `http://127.0.0.1:…` physically cannot have a TLS cert. So this is
    /// the public HTTPS endpoint of the Cloudflare Worker, which 302-redirects back
    /// to the loopback listener (see below). The Worker is stateless and never sees tokens.
    /// Repo: gundemtech/leaf-relay (private).
    /// When changing this URI, update the redirect URI in the Slack OAuth app config.
    public static let redirectURI = "https://oauth.gundem.tech/slack/callback"

    /// Loopback listener — where the Cloudflare Worker 302-redirects after Slack
    /// approval. SlackOAuthService binds an NWListener on this port + catches the auth
    /// code. Port 47824 — one greater than Linear's 47823, for cleaner separation.
    public static let loopbackHost = "127.0.0.1"
    public static let loopbackPort: UInt16 = 47824
    public static let loopbackPath = "/callback"

    /// User scopes only — desktop redirect does not allow bot scopes.
    /// IMPORTANT: for the authorize URL this value goes into the `user_scope` query param,
    /// NOT `scope` — in Slack v2 `scope` is bot-token scopes; user-token scopes
    /// go in a separate parameter.
    /// Phase 4.6.A.3 — added `*:history` scopes for `conversations.history`
    /// endpoint (reactions aggregate). Adding scopes requires full OAuth re-consent
    /// (the user goes through Disconnect → Connect once); backward-compat is broken
    /// for existing alpha.6 tokens.
    /// Phase 4.7.B-10 — added `dnd:read` for `dnd.info` (slack_dnd_state pulse).
    /// Same re-consent caveat: the new scope requires Disconnect → Connect.
    /// Phase 4.7.B-12 — added `files:read` for `search.files` (file upload
    /// aggregate). Combined re-consent with `dnd:read` (B-10) — the user goes
    /// through Disconnect → Connect once for both new scopes.
    @available(*, deprecated, message: "Use SlackScopesService.requested() for live scope set.")
    public static let userScopes = "users:read,users.profile:read,search:read,channels:history,groups:history,im:history,mpim:history,dnd:read,files:read"

    /// Phase Track-3 D3 — canonical comma-separated user_scope parameter built
    /// from `SlackScopesService.requested()` (required core ∪ optional). Slack's
    /// authorize URL accepts `user_scope` as comma-separated (NOT space — as in
    /// GitHub Device Flow). Replaces the static `userScopes` constant in new call
    /// sites (Task 10).
    public static func requestedScopeParameter() -> String {
        SlackScopesService.requested().joined(separator: ",")
    }

    /// DistributedNotification name, posted on connect/disconnect/refreshDenied.
    /// Listeners: ConnectionsSettings (UI re-render), SlackCollector (Phase 4.4 reload).
    public static let integrationChangedNotificationName = "tech.gundem.leaf.slack-integration-changed"

    /// UserDefaults suite/key for the refresh denial flag. Cross-process: the same
    /// suite (`tech.gundem.leaf`) as Linear/GitHub, with a separate provider-specific key.
    public static let userDefaultsSuite = "tech.gundem.leaf"
    public static let refreshDeniedFlagKey = "slack.refreshDenied"
}
