//
//  SupabaseEndpoint.swift
//  LeafCore
//
//  Track 5 / S3 — URL composition + standard header sets for Supabase REST + Edge Function endpoints.
//  Pure value-style — no I/O, easy to unit test.
//

import Foundation

public enum SupabaseEndpoint {

  // MARK: - Auth endpoints

  public static func signupAnonymous(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("auth/v1/signup")
  }

  public static func tokenRefresh(baseURL: URL) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("auth/v1/token"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
    return components.url!
  }

  /// POST /auth/v1/token?grant_type=password — native email+password login.
  /// Body carries email/password; the native app sends NO captcha token — the
  /// shared project runs with global CAPTCHA disabled (SupabaseClient
  /// .signInWithPassword omits gotrue_meta_security when no token is supplied).
  public static func signInWithPassword(baseURL: URL) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("auth/v1/token"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
    return components.url!
  }

  /// POST /auth/v1/signup — email+password registration. The app does NOT
  /// register (registration is web-only, spec §2.2); kept for completeness /
  /// future use and to keep the auth-endpoint surface in one place.
  public static func signUpWithPassword(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("auth/v1/signup")
  }

  /// POST /auth/v1/token?grant_type=pkce — exchange an OAuth authorization
  /// code (caught on the loopback redirect http://127.0.0.1:47825/callback) for
  /// a session, using the PKCE code_verifier. Used by SupabaseOAuthService's
  /// Google/GitHub path.
  public static func oauthToken(baseURL: URL) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("auth/v1/token"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "grant_type", value: "pkce")]
    return components.url!
  }

  /// GET /auth/v1/authorize?provider=...&redirect_to=...&code_challenge=...
  /// Builds the authorize URL opened in the user's DEFAULT browser to start a
  /// Google/GitHub OAuth flow (loopback redirect — see SupabaseOAuthService).
  /// Supabase redirects to `redirect_to` with `?code=...` on success.
  /// `code_challenge_method` is lowercase `s256` per GoTrue's authorize
  /// endpoint convention. NB: we do NOT send a caller `state` — GoTrue brokers
  /// the OAuth flow and owns its own provider-leg state; a caller state breaks
  /// it with `bad_oauth_state`. CSRF/injection protection is PKCE.
  public static func oauthAuthorize(
    baseURL: URL, provider: String, redirectTo: String, codeChallenge: String
  ) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("auth/v1/authorize"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "provider", value: provider),
      URLQueryItem(name: "redirect_to", value: redirectTo),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "s256"),
    ]
    return components.url!
  }

  /// GET /auth/v1/user — the current user object (email, app_metadata.provider,
  /// user_metadata, created_at). Same data the web dashboard reads from
  /// session.user. Requires a Bearer access token (authenticatedHeaders).
  public static func userInfo(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("auth/v1/user")
  }

  // MARK: - Edge Functions

  public static func registerPubkey(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/register_pubkey")
  }

  public static func inviteResolve(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/invite_resolve")
  }

  // MARK: - PostgREST tables

  public static func postInvite(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/invites")
  }

  public static func insertWorkspaceMember(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/workspace_members")
  }

  /// POST /rest/v1/rpc/delete_self_account — invoke the server-side
  /// security-definer function that deletes the calling user's account + data.
  /// Same RPC the web dashboard calls (`sb.rpc('delete_self_account')`).
  public static func rpcDeleteSelfAccount(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/rpc/delete_self_account")
  }

  // MARK: - PostgREST tables — Track 5 / S4 (direct_messages + apns_tokens)

  public static func directMessagesInsert(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/direct_messages")
  }

  public static func directMessagesFetchInbound(
    baseURL: URL,
    workspaceID: String,
    recipientPubkeyHex: String,
    sinceCreatedAtISO: String?,
    limit: Int
  ) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/direct_messages"),
      resolvingAgainstBaseURL: false
    )!
    var items: [URLQueryItem] = [
      URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
      URLQueryItem(name: "recipient_pubkey", value: "eq.\(recipientPubkeyHex)"),
      URLQueryItem(name: "order", value: "created_at.asc"),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let since = sinceCreatedAtISO {
      items.append(URLQueryItem(name: "created_at", value: "gt.\(since)"))
    }
    components.queryItems = items
    return components.url!
  }

  public static func directMessagesFetchOutbound(
    baseURL: URL,
    workspaceID: String,
    senderPubkeyHex: String,
    sinceCreatedAtISO: String?,
    limit: Int
  ) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/direct_messages"),
      resolvingAgainstBaseURL: false
    )!
    var items: [URLQueryItem] = [
      URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
      URLQueryItem(name: "sender_pubkey", value: "eq.\(senderPubkeyHex)"),
      URLQueryItem(name: "order", value: "created_at.asc"),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let since = sinceCreatedAtISO {
      items.append(URLQueryItem(name: "created_at", value: "gt.\(since)"))
    }
    components.queryItems = items
    return components.url!
  }

  /// I5 fix — Track 5 / S4 Stage 6 review: targeted fetch by message_id for
  /// APNs-wake tickOnce path. Avoids 100-row-window race with bounded fetchInbound.
  public static func directMessagesFetchByID(baseURL: URL, messageID: String) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/direct_messages"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "message_id", value: "eq.\(messageID)"),
      URLQueryItem(name: "limit", value: "1"),
    ]
    return components.url!
  }

  public static func directMessagesPatch(baseURL: URL, messageID: String) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/direct_messages"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "message_id", value: "eq.\(messageID)")]
    return components.url!
  }

  public static func apnsTokensUpsert(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/apns_tokens")
  }

  public static func apnsPush(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/apns_push")
  }

  // MARK: - Edge Functions — Track 5 / S6 (cross-post)

  public static func slackPost(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/slack_post")
  }

  public static func linearCreateIssue(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/linear_create_issue")
  }

  // MARK: - PostgREST tables — Track 5 / S5 (team_events)

  public static func teamEventsInsert(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/team_events")
  }

  /// Fetch inbound team events — workspace-scoped, since-watermark filter
  /// (ms epoch encoded as ISO8601 for PostgREST `gt.<iso>` operator).
  public static func teamEventsFetchInbound(
    baseURL: URL,
    workspaceID: String,
    sinceCreatedAtISO: String?,
    limit: Int
  ) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/team_events"),
      resolvingAgainstBaseURL: false
    )!
    var items: [URLQueryItem] = [
      URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
      URLQueryItem(name: "order", value: "created_at.asc"),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let since = sinceCreatedAtISO {
      items.append(URLQueryItem(name: "created_at", value: "gt.\(since)"))
    }
    components.queryItems = items
    return components.url!
  }

  // MARK: - PostgREST tables — Track 5 / S7 (cross_post_log read)

  /// GET /rest/v1/cross_post_log?message_id=in.(<csv>)&select=*
  /// RLS-gated to sender OR recipient (per S6 baseline cross_post_log_party_read policy).
  /// Caller is responsible for non-empty messageIDs (empty input → skip calling this).
  public static func crossPostLogByMessageIDs(_ messageIDs: [String], baseURL: URL) -> URL {
    // PostgREST IN filter: message_id=in.(id1,id2,id3)
    // Comma-separated values inside the parentheses — PostgREST handles quoting
    // for most characters. UUIDs contain only hex + dashes; safe to embed directly.
    let csv = messageIDs.joined(separator: ",")
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/cross_post_log"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "message_id", value: "in.(\(csv))"),
      URLQueryItem(name: "select", value: "*"),
    ]
    return components.url!
  }

  // MARK: - PostgREST tables — Track 5 / S7 (workspace mutations)

  /// POST /rest/v1/workspaces — admin self-insert on workspace creation.
  /// Used by `SupabaseClient.insertWorkspace` (M027 follow-up — server row
  /// is required for `is_workspace_admin` RLS helper to return true).
  public static func workspacesInsert(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/workspaces")
  }

  /// PATCH /rest/v1/workspaces?id=eq.<id>
  /// Used by `SupabaseClient.patchWorkspaceName` and `SupabaseClient.softDeleteWorkspace`.
  /// RLS-gated: only the workspace creator can UPDATE (M025 server policy).
  public static func workspaceByID(_ id: String, baseURL: URL) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/workspaces"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]
    return components.url!
  }

  // MARK: - PostgREST tables — M027 invite-redesign (invite_tokens + join_requests)

  public static func inviteTokensInsert(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("rest/v1/invite_tokens")
  }

  /// GET /rest/v1/invite_tokens?workspace_id=eq.<id>&order=created_at.desc&select=*
  /// RLS-gated by `invite_tokens_admin_write` — only workspace admin sees own rows.
  public static func inviteTokensList(baseURL: URL, workspaceID: String) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/invite_tokens"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
      URLQueryItem(name: "order", value: "created_at.desc"),
      URLQueryItem(name: "select", value: "*"),
    ]
    return components.url!
  }

  /// PATCH /rest/v1/invite_tokens?code=eq.<code>
  /// Used for soft-delete (`SupabaseClient.markInviteTokenDeleted` PATCH `deleted_at`).
  public static func inviteTokensByCode(_ code: String, baseURL: URL) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/invite_tokens"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [URLQueryItem(name: "code", value: "eq.\(code)")]
    return components.url!
  }

  // MARK: - Edge Functions — M027 invite-redesign (closed-mode join handshake)

  public static func createJoinRequest(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/create_join_request")
  }

  public static func cancelJoinRequest(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/cancel_join_request")
  }

  public static func approveJoinRequest(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/approve_join_request")
  }

  public static func declineJoinRequest(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/decline_join_request")
  }

  public static func deleteInviteToken(baseURL: URL) -> URL {
    baseURL.appendingPathComponent("functions/v1/delete_invite_token")
  }

  /// GET /rest/v1/join_requests?workspace_id=eq.<id>&status=eq.pending&order=created_at.desc
  public static func joinRequestsListPending(baseURL: URL, workspaceID: String) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/join_requests"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
      URLQueryItem(name: "status", value: "eq.pending"),
      URLQueryItem(name: "order", value: "created_at.desc"),
      URLQueryItem(name: "select", value: "*"),
    ]
    return components.url!
  }

  /// GET /rest/v1/join_requests?request_id=eq.<id>&limit=1
  /// RLS-gated by `join_requests_self_read` — invitee sees own row only.
  public static func joinRequestByID(_ requestID: String, baseURL: URL) -> URL {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("rest/v1/join_requests"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "request_id", value: "eq.\(requestID)"),
      URLQueryItem(name: "limit", value: "1"),
      URLQueryItem(name: "select", value: "*"),
    ]
    return components.url!
  }

  // MARK: - Header builders

  public static func anonHeaders(anonKey: String) -> [String: String] {
    [
      "apikey": anonKey,
      "Content-Type": "application/json",
    ]
  }

  public static func authenticatedHeaders(anonKey: String, accessToken: String) -> [String: String]
  {
    [
      "apikey": anonKey,
      "Authorization": "Bearer \(accessToken)",
      "Content-Type": "application/json",
    ]
  }

  public static func postgrestInsertHeaders(anonKey: String, accessToken: String) -> [String:
    String]
  {
    [
      "apikey": anonKey,
      "Authorization": "Bearer \(accessToken)",
      "Content-Type": "application/json",
      "Prefer": "return=representation",
    ]
  }

  /// Track 5 / S5 — PostgREST INSERT with merge-duplicates resolution.
  /// 409 conflicts are silently transformed by PostgREST into 200/201
  /// echoing the existing row, so retry storms after transient network
  /// failures don't create duplicate rows. Used by sendTeamEvent where
  /// the broadcast service may re-attempt the same deterministic
  /// (workspace_id, event_id) tuple after a network blip.
  public static func postgrestInsertHeadersIgnoreDuplicates(anonKey: String, accessToken: String)
    -> [String: String]
  {
    [
      "apikey": anonKey,
      "Authorization": "Bearer \(accessToken)",
      "Content-Type": "application/json",
      "Prefer": "return=representation,resolution=merge-duplicates",
    ]
  }

  /// Track 5 / S4 — PostgREST UPSERT via `Prefer: resolution=merge-duplicates`.
  /// Used by `apns_tokens` UPSERT path (token rotation reuses PK).
  public static func postgrestUpsertHeaders(anonKey: String, accessToken: String) -> [String:
    String]
  {
    [
      "apikey": anonKey,
      "Authorization": "Bearer \(accessToken)",
      "Content-Type": "application/json",
      "Prefer": "resolution=merge-duplicates, return=minimal",
    ]
  }

  /// Track 5 / S4 — PATCH via PostgREST. Caller URL composer carries the
  /// `?message_id=eq.<uuid>` query filter; this just adds the standard headers.
  public static func postgrestPatchHeaders(anonKey: String, accessToken: String) -> [String: String]
  {
    [
      "apikey": anonKey,
      "Authorization": "Bearer \(accessToken)",
      "Content-Type": "application/json",
      "Prefer": "return=minimal",
    ]
  }

  /// S7 Stage 6 fix C-I9 — PATCH variant that asks PostgREST to count
  /// affected rows. With `Prefer: count=exact`, the response carries a
  /// `Content-Range` header in the shape `0-(N-1)/N` (or `*/0` when
  /// nothing was touched). Used by destructive workspace ops so RLS-deny
  /// silent-zero-row outcomes become detectable.
  public static func postgrestPatchHeadersWithCount(
    anonKey: String, accessToken: String
  ) -> [String: String] {
    [
      "apikey": anonKey,
      "Authorization": "Bearer \(accessToken)",
      "Content-Type": "application/json",
      "Prefer": "return=minimal, count=exact",
    ]
  }
}
