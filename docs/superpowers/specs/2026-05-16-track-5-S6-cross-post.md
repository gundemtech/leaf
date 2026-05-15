# Track 5 / S6 — Cross-Post Slack + Linear

> Phase-level spec. Track 5 contract: `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md`. Predecessor: S5 (`2026-05-15-track-5-S5-auto-share.md`).
> Status: writing — 2026-05-16.
> Branch: `feature/track-5-S6-cross-post` (leaf) + `feature/track-5-S6-cross-post` (leaf-relay).
> Closes: **UC-T5-4** (Direct message + Linear cross-post Task) + **UC-T5-5** (Cross-post Slack).

---

## §1 Purpose

S6 ships the **outbound cross-post substrate** — explicit opt-in EXIT из E2E для Direct Messages в Slack channel и/или Linear issue. Sender's OAuth token forwarded (never persisted server-side) через два Edge Functions; UI Send sheet получает Channels multi-select + 🔓 privacy warning banner; OAuth scope-bump UX для Slack `chat:write` (уже в `requiredOptional`) и Linear `write` (новый scope).

После S6 merges + VPS deploy:

- Admin opens Team → Send → "Send to Dmitrii" → Type=Task / Body="Закончил OAuth" → expand "Channels" section → ☑ Leaf (default) + ☑ Slack (#leaf-architecture) + ☑ Linear (Backend team) → 🔓 banner "Posting outside Leaf's encrypted channel" highlights → [Send]
- DM encrypted under teamKey → POST `direct_messages` → success (existing S4 flow)
- Fire-and-forget Edge Function calls: `slack_post` + `linear_create_issue` — оба receive sender's OAuth token in request body, validate JWT, call Slack/Linear API once, write `cross_post_log` row, return result
- Mac A confirmation shows per-channel status: ✅ Leaf / ✅ Slack / ✅ Linear (или ⚠️ per-channel error)
- Mac B receives DM via S4 inbox; Slack channel sees parallel message from Anton's user; Linear sees new issue assigned (если resolvable)
- Cross-post failure = log row with error_text + toast; **no auto-retry, no manual resend в MVP** (per contract §9.3)

S6 closes **UC-T5-4** (Task + Linear cross-post) + **UC-T5-5** (Slack cross-post).

**No bi-directional state in S6 initial cut.** Contract §9.2 mentions "When Linear issue closes ... Mac A's Leaf updates corresponding direct_messages.done_at" — this requires Layer B Linear collector enrichment (link `linked_linear_id` from issue close → DM done_at). Defer to S6 follow-up или S7. S6 ships **outbound only**; inbound reaction/comment capture stays existing Layer B (Slack reactions через `slack_message_reactions_changed`, Linear via collector polling).

---

## §2 Goal — fitness function

Each item separate, mechanically-checkable.

| # | Check | How to verify |
|---|---|---|
| **G1** | M025 Supabase migration: `cross_post_log` SELECT RLS (sender OR recipient via `direct_messages` FK join) + `direct_messages.cross_post` UPDATE RLS widened to sender only | `supabase test db` pgTAP `190_cross_post_rls.test.sql` |
| **G2** | `slack_post` Edge Function real body: JWT-gated, accepts `{workspace_id, message_id, channel_id, body, slack_user_token}`, calls `https://slack.com/api/chat.postMessage`, writes `cross_post_log` row, returns `{ok, ts?, channel_id?, error?}` | Deno test `slack_post/test.ts` with mocked Slack API |
| **G3** | `linear_create_issue` Edge Function real body: JWT-gated, accepts `{workspace_id, message_id, team_id, title, description, assignee_id?, linear_user_token}`, calls Linear GraphQL `issueCreate`, writes `cross_post_log`, returns `{ok, issue_id?, identifier?, url?, error?}` | Deno test `linear_create_issue/test.ts` with mocked Linear API |
| **G4** | `LinearScopesService` actor (symmetric с `SlackScopesService`): `requiredCore=["read"]`, `requiredOptional=["write"]`, lazy load from `integrations.scope`, parses Linear's comma-separated scope string | `LinearScopesServiceTests` |
| **G5** | `LinearOAuthEndpoints.scope = "read,write"` (was `"read"`); existing connected users keep working с `read` only; UI banner surfaces missing `write` через `LinearScopesReader` | `LinearOAuthEndpointsTests` regression + `LinearScopesReaderTests` |
| **G6** | `SupabaseClient.triggerSlackPost(workspaceID:, messageID:, channelID:, body:, userToken:)` + `triggerLinearCreate(workspaceID:, messageID:, teamID:, title:, description:, assigneeID:?, userToken:)` — both validate `session.pubkeyClaim`, POST с JWT bearer, parse structured response | `SupabaseClientCrossPostTests` |
| **G7** | `CrossPostPayloadBuilder.slackBody(senderName:, messageText:, attachedEventRef:)` — deterministic format `<sender>: <text>\n\n[Sent via Leaf]\n<optional Linked event ref>`. No event payloads. Sentinel test fence (banned keys: body / file_contents / note_body / email_subject / preview / prompt / response). | `CrossPostPayloadBuilderTests` + sentinel walkback test |
| **G8** | `DirectMessageService.send(...)` accepts new opt params `crossPostSlack: SlackCrossPostRequest?` + `crossPostLinear: LinearCrossPostRequest?`. After successful `direct_messages` INSERT + mirror UPSERT, fires both Edge Function calls in parallel. Returns `SentDirectMessage` extended с `crossPostStatuses: CrossPostStatuses` (per-channel Result). | `DirectMessageServiceCrossPostTests` |
| **G9** | `SlackChannelsReader` @Observable (LeafCore/Team/) — pulls user channels via existing `IntegrationRecord` Slack access token call to `conversations.list` (types=public_channel,private_channel; cached 5 min in-memory) | `SlackChannelsReaderTests` |
| **G10** | `LinearTeamsReader` @Observable — pulls user teams via Linear GraphQL `teams` query (cached 5 min) | `LinearTeamsReaderTests` |
| **G11** | `SendDirectMessageSheet` UI: existing "Channels — Coming in S6" block replaced с interactive `ChannelsPickerSection`. Three checkboxes: Leaf (default ON, locked), Slack (with channel picker dropdown), Linear (with team + assignee picker, only enabled when type=Task). Privacy banner 🔓 "Posting outside Leaf's encrypted channel" rendered prominently когда any cross-post toggle ON. Scope-missing inline banner с [Re-authorize] button per provider | Compile + manual smoke (G18 below) |
| **G12** | Composition root: `LeafApp.init` constructs `SlackChannelsReader` + `LinearTeamsReader` + `LinearScopesReader` @Observable wrappers; injected via `.environment()` | LeafApp compile + manual smoke |
| **G13** | ADR-010 walkback fence: `CrossPostPayloadLeakageTests` — encoded slack body / linear description contain ONLY sender display name + DM body text + optional `[Sent via Leaf]` + optional `Linked event: <kind> <external_ref>`. Probe `RawEvent` payload trees через sentinel injection. | `CrossPostPayloadLeakageTests` (symmetric to S5 `TeamEventPayloadLeakageTests`) |
| **G14** | xcodebuild green for all 5 schemes (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP) | `xcodebuild build` 5x |
| **G15** | SPM `swift test` green (target: baseline ~2210 from S5 + ~80-100 net new) | `swift test` |
| **G16** | All pgTAP tests pass (18 baseline from S5 + 1 new = 19 files; ≥60 assertions) | `supabase test db` |
| **G17** | DispatchCoverageTests + RelayBodyLeakageTests + `TeamEventPayloadLeakageTests` (S5) — все остаются green; cross-post does NOT touch shared event/team-event broadcast path | existing tests pass |
| **G18** | **Manual smoke (signed two-Mac gate, deferred to acceptance session)**: Anton sends DM Handoff/Task с cross-post toggles → Slack channel receives parallel message → Linear team receives new issue → cross_post_log rows present с success refs | deferred — see §13 |

---

## §3 Out of S6 scope

Explicitly **not** in this sub-phase:

- **Bi-directional state sync** (Linear issue close → DM done_at, Slack reply → DM threaded reply). Layer B captures Slack reactions через existing `slack_message_reactions_changed` event_kind, но S6 НЕ wires this to DM state machine. Defer to S6 follow-up or S7.
- **Slack message edit/delete sync** when user edits DM в Leaf — Slack post stays as originally posted (OQ-T5-9 resolution: out of MVP).
- **Slack Block Kit rich formatting** в cross-post — plain text MVP.
- **Linear attachment-based linking** back to Leaf message — manual link в description only (`[Sent via Leaf — message <id>]` is plain text suffix).
- **Cross-post comment-on-existing-Linear-issue** — issue creation only (OQ-T5-S6-2).
- **Auto-retry on cross-post failure** — none. UI shows failure status; manual resend button = future polish (OQ-T5-S6-3).
- **Slack rate-limit exponential backoff** — single attempt, 429 → log "rate_limited" + toast (OQ-T5-S6-4).
- **Tier-gating** (Pro-only cross-post) — S8.
- **Re-share permission** (recipient can re-cross-post received DM) — out of MVP.
- **DM thread cross-post** (only single message + Task) — out of MVP.
- **Settings → Connections > "Disconnect Slack/Linear cross-post separately from collector"** — out of MVP; if user disconnects integration entirely, cross-post toggles auto-disable.
- **Cross-post log UI** (audit view "what did I cross-post") — out of MVP; data в Supabase для debug only.

---

## §4 Architecture overview

```
┌──────────────────────────────────────────────────────────────────────┐
│   Mac A (sender, MenuBarApp)                                         │
│                                                                      │
│   SendDirectMessageSheet (Leaf/Views/Window/Team/)                   │
│   ├─ ChannelsPickerSection (NEW)                                     │
│   │   ├─ ☑ Leaf (locked ON)                                         │
│   │   ├─ ☐ Slack — channel picker (SlackChannelsReader)             │
│   │   │   └─ scope-missing inline banner if chat:write absent        │
│   │   └─ ☐ Linear — team + assignee (LinearTeamsReader)             │
│   │       └─ scope-missing inline banner if write absent             │
│   │       └─ ONLY enabled when type=Task                            │
│   └─ 🔓 Privacy banner (visible when any cross-post toggle ON)       │
│                                                                      │
│   DirectMessageSendReader.send(...) — extended with                 │
│       crossPostSlack: SlackCrossPostRequest?                        │
│       crossPostLinear: LinearCrossPostRequest?                      │
│                                                                      │
│   DirectMessageService.send(...) — extended:                        │
│   1. existing: validate → encode → POST direct_messages → mirror    │
│   2. existing: fire-and-forget APNs trigger                         │
│   3. NEW: read user's Slack/Linear tokens from IntegrationRecord    │
│   4. NEW: build CrossPostPayload from message text (no event data)  │
│   5. NEW: fire-and-forget triggerSlackPost (if requested)           │
│   6. NEW: fire-and-forget triggerLinearCreate (if requested)        │
│   7. NEW: collect Results into CrossPostStatuses for UI render      │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼ JWT-bearer HTTPS
┌──────────────────────────────────────────────────────────────────────┐
│   Supabase                                                           │
│                                                                      │
│   Edge Function `slack_post`                                         │
│   ├─ validate JWT (auth.uid + pubkey claim)                          │
│   ├─ parse request: workspace_id, message_id, channel_id, body,     │
│   │  slack_user_token                                                │
│   ├─ verify caller is sender of message_id (defence-in-depth)        │
│   ├─ POST https://slack.com/api/chat.postMessage                     │
│   │   headers: Authorization: Bearer <slack_user_token>              │
│   │   body: {channel, text, unfurl_links:false}                      │
│   ├─ on 200 ok=true: INSERT cross_post_log(message_id, 'slack',     │
│   │  external_ref=ts, posted_at, error_text=NULL)                    │
│   ├─ on error: INSERT cross_post_log(... error_text=<reason>)        │
│   ├─ token discarded after request (never persisted)                 │
│   └─ return {ok: bool, ts?: string, channel_id?: string, error?}     │
│                                                                      │
│   Edge Function `linear_create_issue`                                │
│   ├─ validate JWT                                                    │
│   ├─ parse request: workspace_id, message_id, team_id, title,       │
│   │  description, assignee_id?, linear_user_token                    │
│   ├─ verify caller is sender of message_id                           │
│   ├─ POST https://api.linear.app/graphql                             │
│   │   mutation issueCreate(input: {teamId, title, description,      │
│   │   assigneeId?})                                                  │
│   ├─ on success: INSERT cross_post_log(message_id, 'linear',        │
│   │  external_ref=issue.id, posted_at)                              │
│   ├─ on error: INSERT cross_post_log(... error_text)                 │
│   ├─ token discarded                                                 │
│   └─ return {ok, issue_id?, identifier?, url?, error?}              │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼ external API
┌──────────────────────────────────────────────────────────────────────┐
│   Slack channel #leaf-architecture / Linear team Backend             │
│   Slack: "Anton: Закончил OAuth, проверь PR #142\n\n                 │
│           [Sent via Leaf]\n                                          │
│           Linked event: github_pr_opened gundemtech/leaf#142"        │
│   Linear: title="Task: SSH keys в Onboarding"                        │
│           description="<full DM body>\n\n[Sent via Leaf — message    │
│                       <message_id>]"                                 │
│           assignee=<linear user resolved from workspace_members>     │
└──────────────────────────────────────────────────────────────────────┘
```

### Why forwarded-token не server-stored

Per Track 5 contract §9.1: "sender's stored Slack token forwarded; never proxied through Leaf company servers in plaintext beyond Edge Function memory".

Implementation choice: Mac POSTs OAuth token в request body над HTTPS. Edge Function:
- Token visible в Edge Function process memory during the single request
- Used once to call Slack/Linear API
- Discarded after response sent
- NEVER written к Supabase storage / logs / cross_post_log

Privacy contract: Leaf company servers (Supabase) hold OAuth token in memory только on-the-fly during cross-post; никакой rest-at-storage of third-party OAuth credentials. Same posture как S4 для APNs token (which IS stored, но only opaque APNs handle, no Slack/Linear creds).

**Why not direct Mac → Slack/Linear (skip Edge Function entirely)**: contract §9 fixes Edge Function as path; reasons — centralized cross_post_log write (single point), future server-side rate limit / abuse mitigation surface, doesn't expose Slack/Linear bearer to client-app reverse engineering (token leaves Mac only via JWT-authed POST к trusted Edge Function).

### Plaintext walkback (ADR-010)

Cross-post body construction is **deterministic** from Direct Message fields only:
- `senderDisplayName` — from `workspace_members.display_name` (sender side)
- `messageText` — DM body (already plaintext, user-authored)
- `attachedEventRef` — optional `(event_kind, external_ref)` tuple from S4 attached event picker, rendered as `Linked event: <kind> <ref>` — JUST reference (e.g., `github_pr_opened gundemtech/leaf#142`), never payload (no commit message, no PR body, no issue body excerpt)

**Never в cross-post body:**
- Event `payload` fields (body / file_contents / note_body / email_subject / preview / prompt / response / file_path / commit_message text / PR body / issue body)
- Other DM bodies (sibling messages в same workspace)
- Detector excerpts (decision reasoning / blocker excerpt / open question text)
- `ai_*` event metadata
- Workspace internal IDs (UUIDs не отправляются в Slack/Linear; only Leaf-side `message_id` опционально в Linear description suffix для future "click-back" linking)

Test fence: `CrossPostPayloadLeakageTests` — sentinel-injection regression. Inject sentinel strings в `RawEvent` payload fields через synthetic events; build cross-post body; assert sentinel absent. Symmetric с S5 `TeamEventPayloadLeakageTests` precedent.

---

## §5 Schema changes

### §5.1 Supabase migration M025 (new)

`leaf-relay/supabase/migrations/20260516120000_cross_post_s6.sql` — содержит:

1. **`cross_post_log` SELECT RLS expansion.** S1 baseline `cross_post_log` table создан без RLS policies (deployed but not exercised). M025 adds:
   ```sql
   ALTER TABLE cross_post_log ENABLE ROW LEVEL SECURITY;

   -- sender (via direct_messages join) reads own cross-post entries
   CREATE POLICY cross_post_log_sender_read ON cross_post_log
     FOR SELECT
     USING (
       message_id IN (
         SELECT message_id FROM direct_messages
         WHERE sender_pubkey = (auth.jwt() ->> 'pubkey')
       )
     );

   -- recipient (via direct_messages join) reads own cross-post entries
   CREATE POLICY cross_post_log_recipient_read ON cross_post_log
     FOR SELECT
     USING (
       message_id IN (
         SELECT message_id FROM direct_messages
         WHERE recipient_pubkey = (auth.jwt() ->> 'pubkey')
       )
     );

   -- INSERT only via Edge Functions (service_role)
   -- No CREATE POLICY for INSERT — service_role bypasses RLS

   -- No UPDATE / DELETE policies — cross_post_log is append-only
   ```

2. **`direct_messages.cross_post` JSONB stays unused в S6.** S4 widened `direct_messages` UPDATE RLS to sender OR recipient (per S4 §9.1 amendment for read_at/done_at). Theoretically recipient could PATCH `cross_post` JSONB field too — but S6 treats `cross_post_log` as authoritative cross-post audit source; `cross_post` JSONB stays default `{}::jsonb`. No M025 RLS change for this column. Future track may denormalize cross_post_log → cross_post JSONB for query optimization; out of S6 scope.

3. **`expires_at` retention on `cross_post_log`.** Per contract §13: 30-day retention. Add:
   ```sql
   ALTER TABLE cross_post_log ADD COLUMN expires_at timestamptz
     GENERATED ALWAYS AS (posted_at + interval '30 days') STORED;
   CREATE INDEX idx_cross_post_log_expires ON cross_post_log(expires_at);
   ```
   Existing `retention_purge` cron (S1) covers this автоматически via standard `expires_at < now()` filter.

### §5.2 No new SQLCipher tables

S6 does NOT add new on-device tables. Cross-post status surfaces только in the sent confirmation UI (transient state per-send); no persistent local store of cross-post history.

Cross-post status from Edge Function returns are captured in `SentDirectMessage.crossPostStatuses` ephemeral struct, displayed in the Send confirmation card, then discarded (next message send creates new struct). If user wants to see what cross-posted historically — they look at Slack/Linear themselves (source of truth lives там).

### §5.3 No new SQLCipher migrations

M024 (S5) remains last on-device migration. **33 SQLCipher tables M001-M024** unchanged.

---

## §6 OAuth scope bumps

### §6.1 Slack `chat:write`

Already в `SlackScopesService.requiredOptional` (Track 3 D3 баseline). S6 lifts presentation:

- `SlackScopesReader.state` exposes new computed `.crossPostReady: Bool` = `await scopes.has("chat:write")`
- `SendDirectMessageSheet` checks `slackScopesReader.crossPostReady` when user toggles ☐ Slack
- If false: inline banner внутри Slack checkbox row "Slack: requires re-auth to send messages" + [Re-authorize] button
- [Re-authorize] action: calls `slackOAuthService.connect()` (existing flow); OAuth re-prompts with full requested scopes (includes `chat:write` already)
- After OAuth success: `slackScopesReader.refresh()` → `crossPostReady` becomes true → banner clears → toggle interactive

No change to `requiredCore` (chat:write stays optional; collector flow doesn't need it).

### §6.2 Linear `write`

New scope addition:

1. `LinearOAuthEndpoints.scope = "read,write"` (was `"read"`). New connecting users grant both upfront.
2. **Existing connected users**: `integrations.scope` для Linear says `"read"` only; new `LinearScopesService` detects missing `write`; UI surfaces inline banner.
3. New `LinearScopesService` actor in `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/` — symmetric с Slack pattern:
   ```swift
   public actor LinearScopesService {
     public static let requiredCore: Set<String> = ["read"]
     public static let requiredOptional: Set<String> = ["write"]
     public static func requested() -> [String] { /* sorted union */ }
     // currentGranted / has / missing / missingOptional / refresh
     // Lazy load from integrations.scope (comma-separated per Linear OAuth response)
   }
   ```
4. `LinearScopesReader` @Observable wrapper (Leaf/Models/) — exposes `.crossPostReady` + `.reauthorize()` action.
5. Banner UX identical to Slack: inline в Linear checkbox row "Linear: requires re-auth to create issues" + [Re-authorize] → `linearOAuthService.connect()` → bump `scope` query param to `"read,write"` → user grants.

### §6.3 Backward compat

Users connected pre-S6 retain Slack/Linear collectors functioning (collectors read only). Cross-post toggle is opt-in per-send; banner surfaces only at use time. No background re-auth prompts, no `requiredCore` bumps (would surface re-auth banner globally в Settings → Connections — uncomfortable for cross-post-uninterested users).

---

## §7 Edge Functions

### §7.1 `slack_post/index.ts` real body

Pattern from `apns_push/index.ts` (S4 reference): JWT auth check → service_role bypass for cron use cases (none here, but pattern preserved) → request parse → external API call → log write → response.

```typescript
// supabase/functions/slack_post/index.ts
serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // JWT auth
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return json({ error: "unauthorized" }, 401);

  // Parse body
  const body = await req.json();
  const { workspace_id, message_id, channel_id, body: slackText, slack_user_token } = body;
  // Validation: all required strings non-empty; slack_user_token starts with "xoxp-" or "xoxb-"
  if (!workspace_id || !message_id || !channel_id || !slackText || !slack_user_token) {
    return json({ ok: false, error: "missing_fields" }, 400);
  }

  // Defence-in-depth: verify caller is sender of message_id
  const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: msg, error: msgErr } = await serviceClient
    .from("direct_messages")
    .select("sender_pubkey")
    .eq("message_id", message_id)
    .single();
  if (msgErr || !msg) return json({ ok: false, error: "message_not_found" }, 404);
  // Pubkey claim from JWT
  const pubkey = await getPubkeyFromAuthHook(user.id, serviceClient);
  if (msg.sender_pubkey !== pubkey) return json({ ok: false, error: "forbidden" }, 403);

  // Call Slack
  const slackRes = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${slack_user_token}`,
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify({
      channel: channel_id,
      text: slackText,
      unfurl_links: false,
      unfurl_media: false,
    }),
  });
  const slackJson = await slackRes.json();

  // Token discarded — never stored, never logged
  if (!slackJson.ok) {
    await serviceClient.from("cross_post_log").insert({
      message_id, channel: "slack",
      external_ref: null,
      error_text: slackJson.error ?? "unknown",
    });
    return json({ ok: false, error: slackJson.error ?? "slack_api_error" }, 200);
  }

  await serviceClient.from("cross_post_log").insert({
    message_id, channel: "slack",
    external_ref: slackJson.ts,
    error_text: null,
  });
  return json({ ok: true, ts: slackJson.ts, channel_id }, 200);
});
```

**Token leakage discipline:**
- `slack_user_token` NEVER logged (no `console.log` near it)
- NEVER stored к `cross_post_log` row (only `external_ref` = `ts`, never token)
- Discarded когда function returns (Edge Function process recycled per-request in Supabase runtime)

### §7.2 `linear_create_issue/index.ts` real body

Symmetric structure. Differences:

- Linear API = GraphQL endpoint `https://api.linear.app/graphql`
- Mutation: `issueCreate(input: {teamId, title, description, assigneeId})`
- Token discriminator: Linear OAuth access tokens look like `lin_oauth_<...>` (вторая check just non-empty)
- Response shape: `{data: {issueCreate: {success: bool, issue: {id, identifier, url}}}}` or errors array
- Assignee resolution: caller (Mac side, see §8) attempts to find Linear user ID by recipient's display name через separate Linear `users` query → passes resolved `assignee_id` или nil to Edge Function. If nil → Linear creates unassigned issue. No `assignee_id` resolution на Edge Function side (keep function focused).

### §7.3 Deno unit tests

Both functions ship with `test.ts` files exercising:
- Auth path (missing JWT → 401, valid JWT → proceed)
- Field validation (missing required → 400)
- External API success path (mocked fetch → 200 ok)
- External API failure path (mocked fetch → 200 ok=false → 200 with `{ok: false, error}`)
- Sender impersonation rejection (different pubkey → 403)
- Token never appears in mocked log row insert

Per S4 precedent, Deno tests execution может be deferred to VPS deploy if `deno install` локально hung (pgTAP + smoke covers function shape).

---

## §8 Mac-side wire layer

### §8.1 SupabaseClient extensions

`Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient+CrossPost.swift` (NEW file):

```swift
public struct SlackCrossPostResult: Sendable, Equatable {
    public let ok: Bool
    public let ts: String?
    public let channelID: String?
    public let error: String?
}

public struct LinearCrossPostResult: Sendable, Equatable {
    public let ok: Bool
    public let issueID: String?
    public let identifier: String?
    public let url: String?
    public let error: String?
}

extension SupabaseClient {
    public func triggerSlackPost(
        workspaceID: UUID,
        messageID: UUID,
        channelID: String,
        body: String,
        slackUserToken: String
    ) async throws -> SlackCrossPostResult { /* POST Edge Function */ }

    public func triggerLinearCreate(
        workspaceID: UUID,
        messageID: UUID,
        teamID: String,
        title: String,
        description: String,
        assigneeID: String?,
        linearUserToken: String
    ) async throws -> LinearCrossPostResult { /* POST Edge Function */ }
}
```

Pattern matches existing `triggerAPNsPush` from S4: JWT-bearer POST, structured response decode, `SupabaseError.identityClaimMissing` guard.

### §8.2 DirectMessageService extension

`DirectMessageService.send(...)` signature extended:

```swift
public func send(
    workspaceID: UUID,
    recipientPubkeyHex: String,
    recipientMemberID: UUID?,
    kind: DirectMessageKind,
    body: String,
    notify: Bool = true,
    replyTo: UUID? = nil,
    crossPostSlack: SlackCrossPostRequest? = nil,    // NEW
    crossPostLinear: LinearCrossPostRequest? = nil    // NEW
) async throws -> SentDirectMessage
```

Where:
```swift
public struct SlackCrossPostRequest: Sendable, Equatable {
    public let channelID: String         // Slack channel ID e.g. "C1234567"
    public let attachedEventRef: AttachedEventRef?  // optional metadata
}

public struct LinearCrossPostRequest: Sendable, Equatable {
    public let teamID: String            // Linear team ID
    public let assigneeID: String?       // optional Linear user ID
    public let attachedEventRef: AttachedEventRef?
}

public struct AttachedEventRef: Sendable, Equatable {
    public let eventKind: String
    public let externalRef: String
}
```

After existing pipeline (validate → encode → POST direct_messages → mirror UPSERT outbound → APNs trigger fire-and-forget):

Cross-post triggers are **parallel-await** (NOT fire-and-forget — каждый await'ится для status результатов в UI), running concurrently через `async let`:

1. If `crossPostSlack` != nil: read `IntegrationRecord(provider: .slack)` → access_token. If nil → return `.failed("not_connected")` immediately (no Edge Function call). Else: build Slack body via `CrossPostPayloadBuilder.slackBody(senderName:, messageText:body, attachedEventRef:)` → `async let slackResult = supabase.triggerSlackPost(...)`.
2. If `crossPostLinear` != nil: read Linear `IntegrationRecord` → access_token. Build title (first 80 chars of body) + description (full body + `\n\n[Sent via Leaf — message <id>]`). `async let linearResult = supabase.triggerLinearCreate(...)`.
3. `await` both (concurrent), collect results.
4. Return `SentDirectMessage` extended:
   ```swift
   public struct CrossPostStatuses: Sendable, Equatable {
       public let slack: SlackCrossPostResult?   // nil if not requested
       public let linear: LinearCrossPostResult? // nil if not requested
   }
   ```

### §8.3 CrossPostPayloadBuilder

`Packages/LeafCore/Sources/LeafCore/Team/CrossPostPayloadBuilder.swift` (NEW):

```swift
public enum CrossPostPayloadBuilder {
    public static func slackBody(
        senderDisplayName: String,
        messageText: String,
        attachedEventRef: AttachedEventRef?
    ) -> String {
        var lines: [String] = []
        lines.append("\(senderDisplayName): \(messageText)")
        lines.append("")
        lines.append("[Sent via Leaf]")
        if let ref = attachedEventRef {
            lines.append("Linked event: \(ref.eventKind) \(ref.externalRef)")
        }
        return lines.joined(separator: "\n")
    }

    public static func linearTitle(messageText: String) -> String {
        // First 80 chars, single-line, trim whitespace
        let single = messageText.replacingOccurrences(of: "\n", with: " ")
        let trimmed = single.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(80))
    }

    public static func linearDescription(
        messageText: String,
        messageID: UUID,
        attachedEventRef: AttachedEventRef?
    ) -> String {
        var blocks: [String] = []
        blocks.append(messageText)
        blocks.append("")
        var footer = "[Sent via Leaf — message \(messageID.uuidString)]"
        if let ref = attachedEventRef {
            footer += "\nLinked event: \(ref.eventKind) \(ref.externalRef)"
        }
        blocks.append(footer)
        return blocks.joined(separator: "\n")
    }
}
```

Pure function (no DB access, no encryption involved). Walkback test asserts banned-key sentinels NEVER appear в output regardless of what's в RawEvent stream.

---

## §9 UI surface

### §9.1 SendDirectMessageSheet — new `ChannelsPickerSection`

Replaces existing "Coming in S6" hint:

```
┌─────────────────────────────────────────────────────┐
│ Channels                                            │
├─────────────────────────────────────────────────────┤
│ ☑ Leaf                              (locked, always)│
│                                                     │
│ ☑ Slack          [#leaf-architecture  ▾]            │
│                                                     │
│ ☑ Linear (Task only)  [Backend ▾]  [Assign: Dima ▾] │
│   ⚠ Linear: requires re-auth to create issues       │
│     [Re-authorize Linear]                           │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ 🔓 Posting outside Leaf's encrypted channel         │
│   Slack workspace admin and Linear API can read     │
│   this message. Anyone with channel/issue access    │
│   can see it.                                       │
└─────────────────────────────────────────────────────┘
```

- **Leaf** — checkbox locked ON (sending DM is the primary action).
- **Slack** — checkbox interactive; when checked, expands to channel picker dropdown (consumes `SlackChannelsReader.channels` array). If `chat:write` scope missing → inline banner replaces dropdown.
- **Linear** — checkbox interactive; **disabled when type != Task** (Handoff/Ping not eligible). When checked: team picker + optional assignee picker. Assignee dropdown shows workspace members; mapping member → Linear user ID handled через `LinearTeamsReader.resolveAssignee(memberID:)` which calls Linear `users` query under the hood. If `write` scope missing → inline banner.
- **Privacy banner** — `LeafCard.warning` style, visible когда any non-Leaf toggle ON. Per Track 5 contract §10 token: `LeafColor.status.warning` background tint + 🔓 icon.

### §9.2 Send confirmation — per-channel status

Existing `.sent(_, status)` state in `SendDirectMessageSheet.SendState` extended:

```swift
case sent(SentDirectMessage, pushDispatchStatus: PushDispatchStatus, crossPostStatuses: CrossPostStatuses)
```

UI renders inline status row per requested channel:
```
✅ Sent to Dmitrii (Leaf)
✅ Posted to #leaf-architecture
⚠️ Linear: rate_limited  (no retry button — manual via Linear directly)
```

If all OK: auto-dismiss sheet после 1.2s (existing behavior preserved when no failures).
If any failure: stay открыто, user читает status, [Done] button manual dismiss.

### §9.3 Cross-process consumers

- `SlackChannelsReader` — `@Observable`, lifecycle owned by LeafApp. Has `.refresh()` action that lazy-fetches `conversations.list` on first read. Cache TTL 5 min in-memory; refresh on Send sheet open (passive).
- `LinearTeamsReader` — same pattern. Fetches `teams { id, name, members { id, name, email } }` GraphQL.
- `LinearScopesReader` — wraps `LinearScopesService`; exposes `.crossPostReady` + `.reauthorize()`.
- `SlackScopesReader` already exists (Track 3 D3); add `.crossPostReady` computed property.

### §9.4 Composition root

`LeafApp.init` extends environment injection:
```swift
.environment(slackChannelsReader)
.environment(linearTeamsReader)
.environment(linearScopesReader)
// existing: slackScopesReader, etc.
```

`SendDirectMessageSheet` consumes via `@Environment(SlackChannelsReader.self)` etc.

---

## §10 Cross-post failure semantics

### §10.1 Per-channel independence

Slack and Linear run **concurrently via `async let`**. Each writes its own `cross_post_log` row. UI shows independent statuses. Failure в одном does NOT cancel the other (no `try`-propagation across the pair — each `Result` captured separately).

### §10.2 Failure surface

- Edge Function returns `{ok: false, error: "<reason>"}` → captured in `CrossPostResult.error`
- Failure types: `"not_connected"` (Mac side, no IntegrationRecord) / `"rate_limited"` (Slack 429 or Linear equiv) / `"slack_api_error"` / `"linear_api_error"` / `"forbidden"` / `"message_not_found"` (defence-in-depth) / `"unknown"`
- UI maps via `humanMessage(for: SlackCrossPostResult)` / `humanMessage(for: LinearCrossPostResult)` helpers — same pattern as S4 `humanMessage(for: LeafError)`.

### §10.3 No auto-retry, no manual resend (MVP)

Per contract §9.3 + OQ-T5-S6-3. Carry-over: future polish may add [Resend to Slack] context menu item на failed cross-post rows; out of S6 initial cut. Documented in §11 carry-overs.

### §10.4 DM persistence regardless

Critical invariant: cross-post failure does NOT affect the underlying DM. `direct_messages` row exists; recipient receives via S4 inbox; Mac A confirmation shows ✅ Leaf even if ⚠️ Slack/Linear.

---

## §11 Carry-overs identified during spec

Items NOT in S6 implementation, documented для future tracks:

- **M1** Bi-directional Linear close → DM done_at sync. Requires Layer B Linear collector enrichment (`linked_leaf_message_id` extraction from Linear description suffix `[Sent via Leaf — message <id>]`). Feature complete S6 stack; defer to S7 or S6 follow-up.
- **M2** Slack reply → DM threaded reply sync. Requires Slack collector polling parent `thread_ts` association with cross-post `external_ref`. Defer to Track 6.
- **M3** Slack message edit/delete sync. Out of MVP scope (OQ-T5-9). Future complexity in v0.2-beta.
- **M4** Manual [Resend to Slack/Linear] context menu в failed cross-post statuses. Polish post-MVP.
- **M5** Backoff on Slack rate-limit (429). Single-attempt currently; defer exponential backoff.
- **M6** Cross-post log audit UI ("show me cross-post history"). Out of MVP.
- **M7** Assignee resolution caching — per-Send-sheet round-trip to Linear `users` query. 5min in-memory cache `LinearTeamsReader.resolveAssignee`. May surface latency in Send sheet open; tolerable < 500ms initial; refine if smoke shows worse.
- **M8** Slack channel filter (private vs public default). MVP shows all both; Track 6 may add toggle.
- **M9** Tier-gating (Pro-only cross-post) — S8.
- **M10** Settings → Connections "Disable cross-post separately" toggle — disconnect entire integration disables cross-post in MVP.
- **M11** Whitepaper sync: `docs/team-sharing/cross-posting.md` v0.1-beta update (per Track 5 §19 — sync at S8, not per-sub-phase).
- **M12** Linear assignee resolution failure UX. If `linearTeamsReader.resolveAssignee(memberID:)` returns nil → silently create issue unassigned + status note "Linear issue created — assignee couldn't be resolved" в send confirmation. Document polish.

---

## §12 Resolved OQs

| OQ | Resolution |
|---|---|
| **OQ-T5-3** (contract) | Linear assignee resolution: optional. Edge Function receives `assignee_id` or nil; nil → unassigned issue + UI note. Mac side attempts mapping via Linear `users` query keyed by `workspace_members.display_name` (best-effort, no fail). |
| **OQ-T5-9** (contract) | Slack edit/delete sync OUT of MVP. Documented как known limitation in whitepaper sync (S8). |
| **OQ-T5-S6-1** | `chat:write` workspace-wide. Slack API does not offer per-channel scoping; membership controls reach. Documented в §6.1. |
| **OQ-T5-S6-2** | Linear cross-post = issue creation ONLY. Comment-on-existing → Track 6. |
| **OQ-T5-S6-3** | Failure: explicit per-channel status в send confirmation + log row. No auto-retry, no manual resend в MVP. |
| **OQ-T5-S6-4** | Single-attempt, no backoff. Defer exponential to v0.2. |
| **OQ-T5-S6-5** | ALL channels user is in, fetched via `conversations.list`. Cache 5 min in-memory. Linear: same approach for teams. |
| **DQ-1 (new)** | Forwarded-token Edge Function pattern. Tokens never persisted server-side. Mac POSTs token в request body; Edge Function uses once, discards. Matches contract §9.1 intent. |
| **DQ-2 (new)** | `LinearScopesService` symmetric с Slack — separate actor in LeafCore. |
| **DQ-3 (new)** | Cross-post body construction deterministic from DM fields only. Sentinel-injection test fence. Never event payloads / other DMs / detector excerpts / ai_* metadata. |
| **DQ-4 (new)** | Scope-missing UX: inline banner в Send sheet, не modal blocker. [Re-authorize] CTA triggers existing OAuth re-auth flow. |

---

## §13 Manual smoke (G18) — signed two-Mac gate

Deferred to acceptance gate session (precedent: S3 G15/G16, S4 G21, S5 G18):

**G18 Cross-post round-trip:**

1. Both Macs running signed build, pointing at production Supabase.
2. Anton's Mac: Settings → Connections → Slack/Linear both connected. If `write` scope missing on Linear (likely since pre-S6 connections) → re-authorize via Connections section.
3. Anton's Mac: Team → click [Send] → To=Dmitrii / Type=Task / Body="SSH keys в Onboarding spec — нужно дописать секцию rotation".
4. Expand "Channels" section. Toggle Leaf ON (locked) / Slack ON → select #leaf-architecture / Linear ON → select Backend team + assignee=Dmitrii.
5. 🔓 banner appears. Click [Send].
6. Within 5s:
   - Anton's Send confirmation: ✅ Leaf / ✅ Slack: #leaf-architecture / ✅ Linear: <issue identifier>
   - Slack #leaf-architecture: "Anton: SSH keys в Onboarding spec — нужно дописать секцию rotation\n\n[Sent via Leaf]"
   - Linear Backend team: new issue "SSH keys в Onboarding spec — нужно дописать секцию rotation" assigned to Dmitrii
   - Dmitrii's Mac: DM appears in Team feed inbox (existing S4 APNs flow)
7. Anton's Mac: query Supabase `cross_post_log` — 2 rows present (slack + linear), external_ref set, error_text NULL.

**G18 negative path:**

1. Anton disconnects Linear in Connections → [Send] with Linear toggle ON → inline banner "Linear: not connected" + toggle disabled.
2. Reconnect Linear но с only `read` scope (skip write grant during OAuth flow somehow — actually Linear has no granular consent UI; this is hard to simulate manually but covered by unit test).
3. Slack rate-limit: spam-send 10 DMs in 5s к same channel → Slack 429 на some → log row error_text="rate_limited" → UI ⚠️ on those.

---

## §14 Test plan

### §14.1 SPM tests (target: baseline ~2210 + ~80-100 net new)

New test files:
- `Packages/LeafCore/Tests/LeafCoreTests/Network/SupabaseClient+CrossPostTests.swift` — 8-12 tests
- `Packages/LeafCore/Tests/LeafCoreTests/Team/CrossPostPayloadBuilderTests.swift` — 6-10 tests (slackBody / linearTitle / linearDescription / attachedEventRef rendering)
- `Packages/LeafCore/Tests/LeafCoreTests/Team/CrossPostPayloadLeakageTests.swift` — sentinel-injection fence, ~15-20 tests
- `Packages/LeafCore/Tests/LeafCoreTests/Team/DirectMessageServiceCrossPostTests.swift` — 6-10 tests (с / без cross-post params; mocked SupabaseClient)
- `Packages/LeafCore/Tests/LeafCoreTests/Integrations/Linear/LinearScopesServiceTests.swift` — 8-12 tests (granted / missing / refresh / parse)
- `Packages/LeafCore/Tests/LeafCoreTests/Integrations/Linear/LinearOAuthEndpointsTests.swift` — regression тест на bumped `scope = "read,write"`
- `Leaf/LeafTests/Team/SlackChannelsReaderTests.swift` — 4-6 tests
- `Leaf/LeafTests/Team/LinearTeamsReaderTests.swift` — 4-6 tests
- `Leaf/LeafTests/Team/LinearScopesReaderTests.swift` — 4-6 tests
- `Packages/LeafCorePrivate/Tests/LeafCorePrivateTests/CrossPostHandshakeIntegrationTests.swift` — moat end-to-end один test (mocked Supabase + Slack + Linear)

### §14.2 pgTAP tests

New file `leaf-relay/supabase/tests/190_cross_post_rls.test.sql`:
- cross_post_log SELECT denied для non-sender-non-recipient
- cross_post_log SELECT allowed для sender
- cross_post_log SELECT allowed для recipient
- cross_post_log INSERT denied для anon
- cross_post_log INSERT allowed для service_role (Edge Function path)
- direct_messages cross_post UPDATE denied для non-sender
- direct_messages cross_post UPDATE allowed для sender
- (3 more for expires_at + retention_purge expectations)

≥ 8 new assertions; 18 baseline files + 1 = 19 files.

### §14.3 Deno tests

`leaf-relay/supabase/functions/slack_post/test.ts` + `linear_create_issue/test.ts`:
- Auth path (6 tests each)
- Field validation (3 each)
- External API mock success (2 each)
- External API mock failure (2 each)
- Sender impersonation rejection (1 each)
- Token never appears в log row (1 each, regression fence)

Execution gated behind `LEAF_RUN_DENO_INTEGRATION=1` env var (precedent S4). Production deploy in VPS session covers runtime verification.

### §14.4 xcodebuild (G14)

5 schemes — same matrix as S5:
- Leaf
- LeafAgent
- LeafCore
- LeafCorePrivate
- LeafMCP

No-sign dev config (`build/test-derived/` deriveddata).

---

## §15 References

- Track 5 contract: `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md` (§6 + §8 + §9 + §13 + §17)
- S4 direct messages spec: `docs/superpowers/specs/2026-05-14-track-5-S4-direct-messages.md`
- S5 auto-share spec: `docs/superpowers/specs/2026-05-15-track-5-S5-auto-share.md`
- Track 3 D3 Slack scope-bump precedent: `Packages/LeafCore/Sources/LeafCore/Integrations/Slack/SlackScopesService.swift`
- Slack API `chat.postMessage`: https://api.slack.com/methods/chat.postMessage
- Slack API `conversations.list`: https://api.slack.com/methods/conversations.list
- Linear GraphQL `issueCreate`: https://developers.linear.app/docs/graphql/working-with-the-graphql-api
- Linear GraphQL `teams`: ibid
- Linear OAuth scopes: https://linear.app/developers/oauth-2-0-authentication
- Whitepaper cross-post (для S8 sync): `~/Desktop/Leaf/leaf-docs/docs/team-sharing/cross-posting.md`

---

## §16 Plan handoff

After spec approval → Stage 4 writes `docs/superpowers/plans/2026-05-16-track-5-S6-cross-post.md` (gitignored — moat). Plan breaks §1-§14 into atomic per-commit tasks:

T1: M025 Supabase migration (cross_post_log RLS + expires_at column)
T2: pgTAP 190 cross-post RLS test
T3: `slack_post` Edge Function real body + Deno test
T4: `linear_create_issue` Edge Function real body + Deno test
T5: `LinearScopesService` actor + tests (LeafCore)
T6: `LinearOAuthEndpoints.scope` bump to "read,write" + endpoint tests
T7: `SupabaseClient+CrossPost` extension (`triggerSlackPost` + `triggerLinearCreate`) + tests
T8: `CrossPostPayloadBuilder` + payload tests + leakage sentinel fence
T9: `DirectMessageService.send(...)` extension с cross-post params + tests
T10: `SlackChannelsReader` + `LinearTeamsReader` + `LinearScopesReader` @Observable wrappers + tests
T11: `SendDirectMessageSheet` UI: ChannelsPickerSection + 🔓 banner + scope-missing inline banners + send confirmation status rows
T12: Composition wiring in LeafApp + `current-state.md` update + manual smoke checklist

12 atomic tasks, ~12-15 commits expected (precedent S5: 13 commits including Stage 6 fix-bundle).
