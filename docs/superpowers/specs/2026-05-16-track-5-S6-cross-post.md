# Track 5 / S6 — Cross-Post Slack + Linear

> Phase-level spec. Track 5 contract: `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md`. Predecessor: S5 (`2026-05-15-track-5-S5-auto-share.md`).
> Status: writing — 2026-05-16.
> Branch: `feature/track-5-S6-cross-post` (leaf) + `feature/track-5-S6-cross-post` (leaf-relay).
> Closes: **UC-T5-4** (Direct message + Linear cross-post Task) + **UC-T5-5** (Cross-post Slack).

---

## §1 Purpose

S6 ships the **outbound cross-post substrate** — explicit opt-in EXIT из E2E для Direct Messages в Slack channel и/или Linear issue. Sender's OAuth token forwarded (never persisted server-side) через два Edge Functions; UI Send sheet получает Channels multi-select + 🔓 privacy warning banner; OAuth scope-bump UX для Slack `chat:write` (уже в `requiredOptional` since Track 3 D3) и Linear `issues:create` (new narrower-than-`write` scope per A3 brainstorm).

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
| **G2** | `slack_post` Edge Function real body: JWT-gated, accepts `{workspace_id, message_id, channel_id, slack_payload (hybrid text+blocks JSON dict per A2), slack_user_token}`, calls `https://slack.com/api/chat.postMessage`, captures `Retry-After` header on 429 (A14), writes `cross_post_log` row, returns `{ok, ts?, channel_id?, error?, retry_after_seconds?}` | Deno test `slack_post/test.ts` with mocked Slack API |
| **G3** | `linear_create_issue` Edge Function real body: JWT-gated, accepts `{workspace_id, message_id, team_id, idempotency_key (UUIDv4 → IssueCreateInput.id per A5), title, description, assignee_id?, linear_user_token}`, calls Linear GraphQL `issueCreate`, writes `cross_post_log`, returns `{ok, issue_id?, identifier?, url?, error?}` | Deno test `linear_create_issue/test.ts` with mocked Linear API |
| **G4** | `LinearScopesService` actor (symmetric с `SlackScopesService`): `requiredCore=["read"]`, `requiredOptional=["issues:create"]` (A3), lazy load from `integrations.scope`, parses Linear's comma-separated scope string | `LinearScopesServiceTests` |
| **G5** | `LinearOAuthEndpoints.scope = "read,issues:create"` (was `"read"`) — **narrower than `write`** per A3 brainstorm; existing connected users keep working с `read` only; UI banner surfaces missing `issues:create` через `LinearScopesReader` | `LinearOAuthEndpointsTests` regression + `LinearScopesReaderTests` |
| **G6** | `SupabaseClient.triggerSlackPost(workspaceID:, messageID:, channelID:, body:, userToken:)` + `triggerLinearCreate(workspaceID:, messageID:, teamID:, title:, description:, assigneeID:?, userToken:)` — both validate `session.pubkeyClaim`, POST с JWT bearer, parse structured response | `SupabaseClientCrossPostTests` |
| **G7** | `CrossPostPayloadBuilder.slackPayload(messageText:, attachedEventRef:)` — returns JSON dict с `text` (notification fallback) + `blocks` (section + context footer) + `unfurl_links:false`. **NO sender prefix** (Slack user-token posts AS user natively per A2). Linear `linearTitle` / `linearDescription` symmetric. Sentinel walkback fence на JSON tree (banned keys: body / file_contents / note_body / email_subject / preview / prompt / response). | `CrossPostPayloadBuilderTests` + sentinel walkback test |
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
│   │       └─ scope-missing inline banner if issues:create absent     │
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

Test fence: `CrossPostPayloadLeakageTests` — sentinel-injection regression. Inject sentinel strings в `RawEvent` payload fields через synthetic events; build cross-post Slack JSON payload + Linear description; recursively walk JSON tree / scan string output; assert sentinel absent. Symmetric с S5 `TeamEventPayloadLeakageTests` precedent.

### §4.5 Bi-directional state — free outbound observability (A12)

Per Linear research finding: existing `LinearCollector` polls `viewerActivityIssues` filtered by `viewer.id`. Cross-post-created Linear issue (sender = viewer) surfaces в sender's own `linear_issue_created` event stream within ≤5 min next tick — **no additional code needed**. Sender's Activity tab will see "Created issue LEA-XXX" automatically.

The `[Sent via Leaf — message <uuid>]` suffix in Linear description is the **inbound handle** Track 6 collectors will use to:
- Parse `<uuid>` from Linear issue body when state transitions to `done`
- Look up DM by message_id in local mirror
- PATCH `direct_messages.done_at` via Supabase (preserves recipient feedback loop)

Out of S6 scope but architecturally enabled now. No schema change required.

Slack inbound (reactions / threaded replies on cross-posted message): Layer B `SlackCollector` already captures via `slack_message_reactions_changed` + `slack_thread_reply_aggregate` (Phase 4.7.A). Linking back to DM requires `(channel_id, ts) ↔ cross_post_log.external_ref` lookup. Defer to S7 — collectors already capture all needed signal.

### §4.6 Multi-workspace OAuth (A17)

S2 multi-workspace substrate enables N Leaf workspaces per device. However, `IntegrationRecord` rows are keyed by `provider` only (no `workspace_id` FK) — **Slack/Linear OAuth tokens are shared across Leaf workspaces** на одном Mac.

S6 cross-post inherits this. Effect:
- User in Leaf workspace A or B sees same Slack channels (one Slack workspace per Mac OAuth).
- Cross-posting from workspace A vs B produces identical Slack message (sender's identity is per-Mac, not per-Leaf-workspace).

Edge case: if user wants separate Slack workspace per Leaf workspace (e.g., personal vs work), MVP requires re-OAuth at Connections settings (replaces single Mac-side row). Per-Leaf-workspace OAuth = out of S6; defer until use case emerges.

---

## §5 Schema changes

### §5.1 Supabase migration M025 (new)

`leaf-relay/supabase/migrations/20260516120100_cross_post_s6.sql` — содержит ONLY the 30-day retention addition (TDD-discovered: pgTAP test revealed S1 already shipped RLS):

1. **`cross_post_log` RLS — already deployed in S1, M025 does NOT touch.** S1 migration `20260513120900_rls_policies.sql` already enabled RLS on cross_post_log + created the unified `cross_post_log_party_read` SELECT policy (sender OR recipient via direct_messages join). The pgTAP test 090 from S1 already exercises this path. M025 explicitly leaves S1's RLS pattern intact; 190 pgTAP regression test asserts S1 baseline still works.

2. **`direct_messages.cross_post` JSONB stays unused в S6.** S4 widened `direct_messages` UPDATE RLS to sender OR recipient (per S4 §9.1 amendment for read_at/done_at). Theoretically recipient could PATCH `cross_post` JSONB field too — but S6 treats `cross_post_log` as authoritative cross-post audit source; `cross_post` JSONB stays default `{}::jsonb`. No M025 RLS change for this column. Future track may denormalize cross_post_log → cross_post JSONB for query optimization; out of S6 scope.

3. **`expires_at` retention on `cross_post_log`.** Per contract §13: 30-day retention. M025 adds:
   ```sql
   ALTER TABLE cross_post_log ADD COLUMN expires_at timestamptz NOT NULL
     DEFAULT (now() + INTERVAL '30 days');
   CREATE INDEX idx_cross_post_log_expires ON cross_post_log(expires_at);
   ```
   **NOT `GENERATED ALWAYS AS`** — Postgres rejects `timestamptz + interval` GENERATED expressions as non-immutable. Plain `DEFAULT` fires at INSERT time, captured per-row. Within a transaction, `now()` returns transaction-start so `posted_at` DEFAULT and `expires_at` DEFAULT evaluate identically; retention semantics identical to generated column. Existing `retention_purge` cron (S1) covers this автоматически via standard `expires_at < now()` filter.

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

### §6.2 Linear `issues:create` (NARROWER than `write` — per A3 brainstorm)

Per Linear OAuth docs: `write` is broad; `issues:create` is narrower scope for issue creation specifically. S6 uses narrower:

1. `LinearOAuthEndpoints.scope = "read,issues:create"` (was `"read"`). New connecting users grant both upfront. Privacy posture: token compromise blast radius bounded to creating-issues; cannot edit/delete existing issues, modify labels, etc.
2. **Existing connected users**: `integrations.scope` для Linear says `"read"` only; new `LinearScopesService` detects missing `issues:create`; UI surfaces inline banner.
3. New `LinearScopesService` actor in `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/` — symmetric с Slack pattern:
   ```swift
   public actor LinearScopesService {
     public static let requiredCore: Set<String> = ["read"]
     public static let requiredOptional: Set<String> = ["issues:create"]
     public static func requested() -> [String] { /* sorted union */ }
     // currentGranted / has / missing / missingOptional / refresh
     // Lazy load from integrations.scope (comma-separated per Linear OAuth response)
   }
   ```
4. `LinearScopesReader` @Observable wrapper (Leaf/Models/) — exposes `.crossPostReady` + `.reauthorize()` action.
5. Banner UX identical to Slack: inline в Linear checkbox row "Linear: requires re-auth to create issues" + [Re-authorize] → `linearOAuthService.connect()` → bump `scope` query param to `"read,issues:create"` → user grants.

Future `comments:create` scope-bump (when comment-on-existing-issue cross-post lands in Track 6) — additive re-auth, same pattern. Documented in carry-over M13.

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

  // Parse body — A2: slack_payload is pre-built JSON dict (text + blocks)
  const body = await req.json();
  const { workspace_id, message_id, channel_id, slack_payload, slack_user_token } = body;
  // Validation: required strings non-empty; slack_user_token format (xoxp-/xoxb- prefix)
  if (!workspace_id || !message_id || !channel_id || !slack_payload || !slack_user_token) {
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

  // Call Slack — slack_payload already has channel, text, blocks, unfurl_*
  const slackRes = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${slack_user_token}`,
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify(slack_payload),
  });
  const slackJson = await slackRes.json();

  // Token discarded — never stored, never logged
  if (!slackJson.ok) {
    // A14: capture Retry-After header from 429 path
    const retryAfter = slackRes.headers.get("Retry-After");
    const errorCode = slackJson.error ?? "unknown";
    const errorText = (errorCode === "rate_limited" && retryAfter)
      ? `rate_limited:retry_after_${retryAfter}s`
      : errorCode;
    await serviceClient.from("cross_post_log").insert({
      message_id, channel: "slack",
      external_ref: null,
      error_text: errorText,
    });
    return json({
      ok: false,
      error: errorCode,
      retry_after_seconds: retryAfter ? Number(retryAfter) : null
    }, 200);
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

Symmetric structure to slack_post. Differences:

- Linear API = GraphQL endpoint `https://api.linear.app/graphql`
- Mutation: `issueCreate(input: {id: $uuid, teamId, title, description, assigneeId})`
  - **`id: $uuid` is Linear's idempotency key** (A5 brainstorm finding) — Mac generates UUIDv4 per cross-post attempt, passes verbatim. Retry-safe: second submission with same `id` returns same issue, не creates duplicate.
- Token discriminator: Linear OAuth access tokens look like `lin_oauth_<...>` (вторая check just non-empty)
- Response shape: `{data: {issueCreate: {success: bool, lastSyncId: number, issue: {id, identifier, url}}}}` or errors array
- Error response shape (per A14 research): HTTP **400** with `{errors: [{message, extensions: {code: "RATELIMITED"/"AUTHENTICATION_ERROR"/"FORBIDDEN"/"INVALID_INPUT"}}]}` — map to LinearCrossPostResult
- Assignee resolution: caller (Mac side, see §8) does fuzzy-match resolution + passes resolved `assigneeID` или nil to Edge Function. If nil → Linear creates unassigned issue. No `assignee_id` resolution на Edge Function side.
- Authorship: existing `actor=user` OAuth setting → Linear issue shows "Created by Anton" without app badge (A8 research finding).
- Sender's own observability: existing `LinearCollector` polls `viewerActivityIssues` filtered by `viewer.id` — created issue surfaces в sender's own `linear_issue_created` event stream within ≤5 min next tick. **No additional code needed for self-attribution** (§4.5).

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
    public let retryAfterSeconds: Int?   // A14: present on rate_limited from Slack 429 Retry-After header
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
        slackPayload: [String: Any],          // A2: pre-built hybrid text + blocks JSON dict
        slackUserToken: String
    ) async throws -> SlackCrossPostResult { /* POST Edge Function */ }

    public func triggerLinearCreate(
        workspaceID: UUID,
        messageID: UUID,
        teamID: String,
        idempotencyKey: UUID,                  // A5: Linear IssueCreateInput.id
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
    public let assigneeID: String?       // optional Linear user ID (A4 fuzzy resolution at call site)
    public let idempotencyKey: UUID      // A5: Mac-generated UUIDv4 → Linear IssueCreateInput.id
    public let attachedEventRef: AttachedEventRef?
}

public struct AttachedEventRef: Sendable, Equatable {
    public let eventKind: String
    public let externalRef: String
}
```

After existing pipeline (validate → encode → POST direct_messages → mirror UPSERT outbound → APNs trigger fire-and-forget):

Cross-post triggers are **parallel-await** (NOT fire-and-forget — каждый await'ится для status результатов в UI), running concurrently через `async let`:

1. If `crossPostSlack` != nil: read `IntegrationRecord(provider: .slack)` → access_token. If nil → return `.failed("not_connected")` immediately (no Edge Function call). Else: build Slack JSON payload via `CrossPostPayloadBuilder.slackPayload(messageText:body, attachedEventRef:)` (A2: no sender prefix — user token attribution natively shows sender) → `async let slackResult = supabase.triggerSlackPost(workspaceID:, messageID:, channelID:, slackPayload:, slackUserToken:)`.
2. If `crossPostLinear` != nil: read Linear `IntegrationRecord` → access_token. Build title (first 80 chars of body, single-line) + description (full body + `\n\n[Sent via Leaf — message <id>]` + optional event ref). **`idempotencyKey = UUID()`** generated here, passed verbatim to Edge Function (A5 retry-safety). `async let linearResult = supabase.triggerLinearCreate(workspaceID:, messageID:, teamID:, idempotencyKey:, title:, description:, assigneeID:, linearUserToken:)`.
3. `await` both (concurrent), collect results.
4. Return `SentDirectMessage` extended:
   ```swift
   public struct CrossPostStatuses: Sendable, Equatable {
       public let slack: SlackCrossPostResult?   // nil if not requested
       public let linear: LinearCrossPostResult? // nil if not requested
   }
   ```

### §8.3 CrossPostPayloadBuilder

`Packages/LeafCore/Sources/LeafCore/Team/CrossPostPayloadBuilder.swift` (NEW). A2-revised: Slack returns Block Kit-hybrid JSON dict; sender prefix dropped (user-token attribution natively).

```swift
public enum CrossPostPayloadBuilder {
    /// A2: Hybrid text + blocks payload for chat.postMessage.
    /// - `text`: notification fallback (push, screen reader)
    /// - `blocks`: visual rendering (section + context footer)
    /// - `unfurl_*`: suppress link previews
    /// NO sender prefix — user-token natively attributes to sender in Slack UI
    public static func slackPayload(
        channelID: String,
        messageText: String,
        attachedEventRef: AttachedEventRef?
    ) -> [String: Any] {
        let footer = attachedEventRef.map { ref in
            "Sent via Leaf · `\(ref.eventKind) \(ref.externalRef)`"  // backticks suppress unfurl
        } ?? "Sent via Leaf"

        var blocks: [[String: Any]] = [
            ["type": "section", "text": ["type": "mrkdwn", "text": messageText]],
            ["type": "context", "elements": [["type": "mrkdwn", "text": footer]]],
        ]

        return [
            "channel": channelID,
            "text": messageText,             // fallback
            "blocks": blocks,                // visual
            "unfurl_links": false,
            "unfurl_media": false,
        ]
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
        // A2: Linear shows sender in metadata bar — no prefix needed in description body.
        // GFM markdown supported (A9 research finding).
        var blocks: [String] = []
        blocks.append(messageText)
        blocks.append("")
        var footer = "---\n[Sent via Leaf — message \(messageID.uuidString)]"
        if let ref = attachedEventRef {
            footer += "\nLinked event: \(ref.eventKind) \(ref.externalRef)"
        }
        blocks.append(footer)
        return blocks.joined(separator: "\n")
    }
}
```

Pure function (no DB access, no encryption involved). Walkback test:
- Recursively walks the Slack payload JSON tree (Dictionary / Array / String values)
- Scans Linear description as flat string
- Asserts banned-key sentinels (body / file_contents / note_body / email_subject / preview / prompt / response / commit_message / pr_body / issue_body) NEVER appear in output regardless of what's в RawEvent stream upstream.

### §8.4 LinearUsersResolver (A4 — fuzzy assignee resolution)

`Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearUsersResolver.swift` (NEW). Performs Leaf member → Linear user ID resolution per A4 brainstorm.

```swift
public actor LinearUsersResolver {
    public struct ResolvedUser: Sendable, Equatable {
        public let id: String          // Linear user UUID
        public let displayName: String
        public let name: String        // full name
    }

    private let provider: LinearGraphQLProvider   // existing collector dependency
    private var cache: [ResolvedUser]?
    private var cachedAt: Date?
    private let ttl: TimeInterval = 300  // 5 min

    public init(provider: LinearGraphQLProvider) {
        self.provider = provider
    }

    /// Resolves Leaf member display name → Linear user ID.
    /// Returns nil if zero or multiple ambiguous matches — caller treats as unassigned.
    /// Logic:
    ///   1. Lazy-fetch viewer's accessible Linear users (cached 5 min)
    ///   2. Exact case-insensitive displayName match → unique → return id
    ///   3. Fallback: contains match (case-insensitive)
    ///   4. If unique → return; if 0 or >1 → return nil
    public func resolve(displayName: String) async throws -> String? {
        let users = try await refreshIfStale()
        let needle = displayName.lowercased().trimmingCharacters(in: .whitespaces)

        // Step 2: exact case-insensitive
        let exact = users.filter { $0.displayName.lowercased() == needle }
        if exact.count == 1 { return exact[0].id }
        if exact.count > 1 { return nil }  // ambiguous

        // Step 3: contains
        let contains = users.filter { $0.displayName.lowercased().contains(needle) }
        if contains.count == 1 { return contains[0].id }
        return nil  // 0 or ambiguous
    }

    private func refreshIfStale() async throws -> [ResolvedUser] {
        if let cache, let cachedAt, Date().timeIntervalSince(cachedAt) < ttl {
            return cache
        }
        // GraphQL: users(first: 250) { nodes { id name displayName email } }
        let fetched = try await provider.fetchAccessibleUsers()  // new method
        cache = fetched
        cachedAt = Date()
        return fetched
    }
}
```

Send sheet flow:
1. User selects Linear team + recipient (from `workspace_members` dropdown).
2. Mac calls `linearUsersResolver.resolve(displayName: recipientMember.displayName)`.
3. If `nil` → inline notice in Send sheet "⚠ Will create unassigned issue (couldn't find '<name>' in Linear)" — non-blocking, user can still send.
4. On Send: pass resolved `assigneeID` (or nil) to `LinearCrossPostRequest`.

Future M14 polish: manual Linear-user picker dropdown for ambiguous-match cases (post-MVP).

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
│   ⚠ Will create unassigned issue (couldn't find    │
│     'Dmitrii' in Linear)              [A4 fallback] │
│                                                     │
│   ⚠ Linear: requires re-auth to create issues       │
│     [Re-authorize Linear]                           │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│ 🔓 Posting outside Leaf's encrypted channel         │
│   Slack workspace admin and Linear API can read     │
│   this message. Anyone with channel/issue access    │
│   can see it.                                       │
└─────────────────────────────────────────────────────┘

   Body textarea placeholder hint (A15):
   "Type @-mentions explicitly (e.g. @Dmitrii) — they appear as
    text in Slack messages (no auto-ping in v1)."
```

- **Leaf** — checkbox locked ON (sending DM is the primary action).
- **Slack** — checkbox interactive; when checked, expands to channel picker dropdown (consumes `SlackChannelsReader.channels` array). If `chat:write` scope missing → inline banner replaces dropdown.
- **Linear** — checkbox interactive; **disabled when type != Task** (Handoff/Ping not eligible). When checked: team picker (consumes `LinearTeamsReader.teams`) + optional assignee picker (preselected from `workspace_members.display_name` resolution via `LinearUsersResolver`). If resolve returns nil → inline notice "Will create unassigned issue (couldn't find '<name>' in Linear)" — non-blocking; user can still send. If `issues:create` scope missing → inline banner replaces all Linear inputs.
- **Privacy banner** — `LeafCard.warning` style, visible когда any non-Leaf toggle ON. Per Track 5 contract §10 token: `LeafColor.status.warning` background tint + 🔓 icon.
- **A15 placeholder hint** in body textarea: documents Slack @-mention limitation (raw text only; no auto-ping in MVP per A15 brainstorm).

### §9.2 Send confirmation — per-channel status (A9 timing fix)

Existing `.sent(_, status)` state in `SendDirectMessageSheet.SendState` extended:

```swift
case sent(SentDirectMessage, pushDispatchStatus: PushDispatchStatus, crossPostStatuses: CrossPostStatuses)
```

UI renders inline status row per requested channel:
```
✅ Sent to Dmitrii (Leaf)
✅ Posted to #leaf-architecture
⚠️ Linear: rate_limited (retry after 4s)   ← A14: surface retry-after
```

Timing (A9):
- **All OK**: auto-dismiss sheet after **1.5s** (allows user to glance over success rows).
- **Any failure**: stay open indefinitely; user reads status; [Done] button for manual dismiss.

No retry button (per contract §9.3 — manual resend deferred to future polish, M4 carry-over).

### §9.3 Cross-process consumers — fetch-on-connect + lazy refresh (A8 brainstorm)

- `SlackChannelsReader` — `@Observable` actor wrapper, lifecycle owned by LeafApp. Methods:
  - `.refreshOnConnect()` — called once after OAuth success (user already waiting for "fetching workspace" step) → fetch `conversations.list` → populate in-memory cache. Eliminates first-Send-sheet-open spinner.
  - `.refreshIfStale(maxAge: 5min)` — called on Send sheet open. No-op if cache fresh; background refresh if stale.
  - `.channels: [SlackChannel]` — synchronous read.
  - Periodic refresh: `SlackCollector.tick` extended to call `refreshIfStale` every 5 min piggy-back. Cold launch refetches first Send sheet open.
- `LinearTeamsReader` — symmetric. Fetches `viewer { teams { nodes { id, name, key } } }` GraphQL on connect (A4 research: `viewer.teams` returns user's accessible teams; standard Relay Connection).
- `LinearUsersResolver` (§8.4) — lazy on first `resolve()` call, cached 5 min. NOT prefetched on connect (rarely needed — only at cross-post time with Linear toggle ON).
- `LinearScopesReader` — wraps `LinearScopesService`; exposes `.crossPostReady` + `.reauthorize()`.
- `SlackScopesReader` already exists (Track 3 D3); add `.crossPostReady` computed property.

### §9.4 Composition root

`LeafApp.init` extends environment injection:
```swift
.environment(slackChannelsReader)
.environment(linearTeamsReader)
.environment(linearUsersResolver)    // §8.4
.environment(linearScopesReader)
// existing: slackScopesReader (extend with .crossPostReady), etc.
```

`SendDirectMessageSheet` consumes via `@Environment(SlackChannelsReader.self)` etc. 4 new env readers (A11 brainstorm: separate readers preferred over composite for single-responsibility + future S7 Team UI reuse).

---

## §10 Cross-post failure semantics

### §10.1 Per-channel independence

Slack and Linear run **concurrently via `async let`**. Each writes its own `cross_post_log` row. UI shows independent statuses. Failure в одном does NOT cancel the other (no `try`-propagation across the pair — each `Result` captured separately).

### §10.2 Failure surface

- Edge Function returns `{ok: false, error: "<reason>", retry_after_seconds?: number}` → captured in `CrossPostResult.error` + `retryAfterSeconds` (A14)
- Failure types (Slack — codes from A14 research):
  - `invalid_auth` — token revoked → Mac should trigger `slackOAuthService.disconnect()` (carry-over M19)
  - `channel_not_found` — stale channel ID, force `SlackChannelsReader.refresh()`
  - `not_in_channel` — user removed from channel
  - `rate_limited` — accompanied by `retry_after_seconds` (Slack `Retry-After` header)
  - `missing_scope` — `chat:write` not granted (shouldn't happen if scope-bump UX worked)
  - `fatal_error` — Slack-side; retry-able
- Failure types (Linear — codes from A14 research):
  - `RATELIMITED` — Linear's complexity limit exceeded; no Retry-After but `X-RateLimit-Complexity-Reset` header indicates window
  - `AUTHENTICATION_ERROR` — revoked token
  - `FORBIDDEN` — missing `issues:create` scope
  - `INVALID_INPUT` — bad teamId/assigneeId (assignee resolution should prevent this; defensive)
- Mac-side errors: `"not_connected"` (no IntegrationRecord) / `"forbidden"` / `"message_not_found"` (Edge Function defence-in-depth) / `"unknown"`
- UI maps via `humanMessage(for: SlackCrossPostResult)` / `humanMessage(for: LinearCrossPostResult)` helpers — same pattern as S4 `humanMessage(for: LeafError)`. For `rate_limited` with `retryAfterSeconds`: render "Slack: rate-limited, retry after N seconds".

### §10.3 No auto-retry, no manual resend (MVP)

Per contract §9.3 + OQ-T5-S6-3. Carry-over: future polish may add [Resend to Slack] context menu item на failed cross-post rows; out of S6 initial cut. Documented in §11 carry-overs.

### §10.4 DM persistence regardless

Critical invariant: cross-post failure does NOT affect the underlying DM. `direct_messages` row exists; recipient receives via S4 inbox; Mac A confirmation shows ✅ Leaf even if ⚠️ Slack/Linear.

---

## §11 Carry-overs identified during spec

Items NOT in S6 implementation, documented для future tracks:

- **M1** Bi-directional Linear close → DM done_at sync. Requires Layer B Linear collector enrichment (`linked_leaf_message_id` extraction from Linear description suffix `[Sent via Leaf — message <id>]`). Feature complete S6 stack; defer to S7 or S6 follow-up. Architecturally enabled — Linear `description` suffix is the inbound handle (§4.5).
- **M2** Slack reply → DM threaded reply sync. Requires Slack collector polling parent `thread_ts` association with cross-post `external_ref`. Defer to Track 6.
- **M3** Slack message edit/delete sync. Out of MVP scope (OQ-T5-9). Future complexity in v0.2-beta. `chat:write` scope already covers `chat.update` / `chat.delete` per A14 research — no additional scope-bump needed.
- **M4** Manual [Resend to Slack/Linear] context menu в failed cross-post statuses. Polish post-MVP. Linear retry safe (idempotency key §8.2); Slack retry may duplicate (no idempotency).
- **M5** Backoff on Slack rate-limit (429). MVP captures `Retry-After` header and surfaces в UI (A14); exponential auto-retry deferred.
- **M6** Cross-post log audit UI ("show me cross-post history"). Out of MVP.
- **M7** Assignee resolution: see §8.4 — fuzzy match with 5min cache. Refinement: Jaro-Winkler similarity threshold (more nuanced than substring). MVP uses exact + contains.
- **M8** Slack channel filter (private vs public default). MVP shows all both; Track 6 may add toggle.
- **M9** Tier-gating (Pro-only cross-post) — S8.
- **M10** Settings → Connections "Disable cross-post separately" toggle — disconnect entire integration disables cross-post in MVP.
- **M11** Whitepaper sync: `docs/team-sharing/cross-posting.md` v0.1-beta update (per Track 5 §19 — sync at S8, not per-sub-phase).
- **M12** Linear assignee resolution failure UX. Inline notice in Send sheet (already in §9.1); polish может show manual Linear-user picker dropdown for ambiguous matches.
- **M13** Linear `comments:create` scope-bump (Track 6 — when comment-on-existing-issue cross-post feature lands). Additive re-auth UX, same pattern as `issues:create`.
- **M14** Picker fallback UX when `LinearUsersResolver` returns multiple ambiguous matches — manual Linear user dropdown в Send sheet. MVP: inline notice + create unassigned.
- **M15** Denormalization `direct_messages.cross_post` JSONB via Edge Function PATCH or DB trigger (A7 brainstorm) — for S7 Team feed fast-read of cross-post badges. MVP uses `cross_post_log` JOIN.
- **M16** Subtle "Cross-post ready" indicator on Connections card after re-auth confirms scope grant. A10 polish.
- **M17** S7 surfaces recipient-side "Also posted to X" indicator in Team feed. RLS already permits recipient read of `cross_post_log` (M025); just UI surface needed.
- **M18** Slack `@user` mention resolution: `users.lookupByEmail` / `users.list` fuzzy match to convert literal `@Dmitrii` text to `<@U012AB3CD>` Slack-mention form. A15 — needs new Slack API call; defer to v1.1 per user feedback.
- **M19** On `invalid_auth` from Slack/Linear, auto-trigger `*OAuthService.disconnect()` to clear stale row. Mac side cleanup. Defer — current state.
- **M20** LeafCorePrivate moat impls — `ProdSlackChannelsProvider` / `ProdLinearTeamsProvider` / extend `ProdLinearGraphQLProvider.fetchAccessibleUsers`. T13 ships Stubs (empty arrays) → cross-post UI pickers show no channels/teams → user can't actually cross-post until LeafCorePrivate impls land. **Blocks G18 smoke**. Production wiring incremental post-merge.
- **M21** Track-wide Scopes/Reader DB-fail fallback robustness — `LinearScopesService(grantedOverride: [])` fallback (LeafApp.swift:163-168) silently disables cross-post UI permanently if DB open fails. Same risk applies to `SlackScopesService` (Track 3 D3 pattern) and `GitHubScopesService`. Either propagate DB-open failure to UI error banner OR retry DB-open lazy on each refresh. Defer to Track 6 cleanup.
- **M22** Linear `X-RateLimit-Complexity-Reset` header capture — symmetric to Slack `Retry-After` (I1). Currently `linear_create_issue/index.ts` only maps status code to `ratelimited` without surfacing reset time. Defer to polish post-MVP.
- **M23** SwiftUI sheet `.sent` state — `Task.checkCancellation()` inside the 1.5s auto-dismiss sleep would exit cleaner on view dismissal mid-sleep. Defer.

---

## §12 Resolved OQs

| OQ | Resolution |
|---|---|
| **OQ-T5-3** (contract) | Linear assignee resolution via `LinearUsersResolver` (§8.4): fetch viewer's accessible users (cached 5min) → exact case-insensitive displayName match → contains fallback → nil if 0/multiple. Edge Function receives `assigneeID` or nil; nil → unassigned issue + UI note. |
| **OQ-T5-9** (contract) | Slack edit/delete sync OUT of MVP. `chat:write` scope already covers edit/delete per A14 research (no scope-bump barrier later). Documented как known limitation in whitepaper sync (S8). |
| **OQ-T5-S6-1** | `chat:write` workspace-wide. Slack API does not offer per-channel scoping; membership controls reach. Documented в §6.1. |
| **OQ-T5-S6-2** | Linear cross-post = issue creation ONLY. Comment-on-existing → Track 6 (M13 scope-bump for `comments:create`). |
| **OQ-T5-S6-3** | Failure: explicit per-channel status в send confirmation + log row. **A14 enhancement**: capture Slack `Retry-After` header on 429, surface seconds в status row. No auto-retry, no manual resend в MVP. |
| **OQ-T5-S6-4** | Single-attempt, no backoff. Slack `Retry-After` surfaced to user. Defer exponential auto-retry. |
| **OQ-T5-S6-5** | ALL channels user is in, fetched via `conversations.list`. **A8 enhancement**: fetch-on-connect + lazy 5min refresh + collector tick piggy-back. Linear: same approach (`viewer.teams`). |
| **DQ-1 (new)** | Forwarded-token Edge Function pattern. Tokens never persisted server-side. Mac POSTs token в request body; Edge Function uses once, discards. Matches contract §9.1 intent. |
| **DQ-2 (new)** | `LinearScopesService` symmetric с Slack — separate actor in LeafCore. |
| **DQ-3 (new)** | Cross-post body construction deterministic from DM fields only. Sentinel-injection test fence on JSON tree (Slack hybrid payload) + flat string (Linear description). Never event payloads / other DMs / detector excerpts / ai_* metadata. |
| **DQ-4 (new)** | Scope-missing UX: inline banner в Send sheet, не modal blocker. [Re-authorize] CTA triggers existing OAuth re-auth flow. |
| **A2 (alternatives)** | Slack message: hybrid `text` (fallback) + `blocks` (section + context footer) NOT plain text only. Drop sender prefix (user-token attribution natively shows sender). |
| **A3 (alternatives)** | Linear scope `read,issues:create` not `read,write` — narrower blast radius. Future `comments:create` additive in Track 6. |
| **A5 (alternatives)** | Linear `IssueCreateInput.id = UUIDv4` idempotency key generated Mac-side. Retry-safe; future manual-resend polish trivially safe. |
| **A14 (alternatives)** | Capture Slack `Retry-After` header from 429, surface seconds в UI. NO auto-retry в MVP. |
| **A15 (alternatives)** | Slack `@user` mention literal text only в MVP (no auto-ping). Placeholder hint in body textarea documents this. Linear's GFM markdown `@mention` syntax works natively for Linear path. |
| **A17 (alternatives)** | Slack/Linear OAuth tokens shared across Leaf workspaces on one Mac (per-device `IntegrationRecord`). Per-Leaf-workspace OAuth = future. |

---

## §13 Manual smoke (G18) — signed two-Mac gate

Deferred to acceptance gate session (precedent: S3 G15/G16, S4 G21, S5 G18):

**G18 Cross-post round-trip:**

1. Both Macs running signed build, pointing at production Supabase.
2. Anton's Mac: Settings → Connections → Slack/Linear both connected. If `issues:create` scope missing on Linear (likely since pre-S6 connections were `read`-only) → re-authorize via Connections section. If `chat:write` missing on Slack (only if connected before Track 3 D3) → also re-authorize.
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
- `Packages/LeafCore/Tests/LeafCoreTests/Network/SupabaseClient+CrossPostTests.swift` — 8-12 tests (включая retry_after_seconds passthrough, idempotency key round-trip)
- `Packages/LeafCore/Tests/LeafCoreTests/Team/CrossPostPayloadBuilderTests.swift` — 6-10 tests (slackPayload JSON dict shape / linearTitle / linearDescription / attachedEventRef rendering / no-sender-prefix invariant)
- `Packages/LeafCore/Tests/LeafCoreTests/Team/CrossPostPayloadLeakageTests.swift` — sentinel-injection fence on JSON tree (Slack hybrid) + flat string (Linear), ~15-20 tests
- `Packages/LeafCore/Tests/LeafCoreTests/Team/DirectMessageServiceCrossPostTests.swift` — 6-10 tests (с / без cross-post params; mocked SupabaseClient; idempotencyKey UUIDv4 generated each send)
- `Packages/LeafCore/Tests/LeafCoreTests/Integrations/Linear/LinearScopesServiceTests.swift` — 8-12 tests (granted / missing / refresh / parse; **`requiredOptional = ["issues:create"]`** per A3)
- `Packages/LeafCore/Tests/LeafCoreTests/Integrations/Linear/LinearOAuthEndpointsTests.swift` — regression test на bumped `scope = "read,issues:create"` per A3
- `Packages/LeafCore/Tests/LeafCoreTests/Integrations/Linear/LinearUsersResolverTests.swift` — 8-12 tests (exact / contains / multi-match-nil / empty-list / cache TTL / fetchAccessibleUsers mock)
- `Leaf/LeafTests/Team/SlackChannelsReaderTests.swift` — 4-6 tests (refreshOnConnect, refreshIfStale TTL behavior)
- `Leaf/LeafTests/Team/LinearTeamsReaderTests.swift` — 4-6 tests (refreshOnConnect, refreshIfStale)
- `Leaf/LeafTests/Team/LinearScopesReaderTests.swift` — 4-6 tests
- `Packages/LeafCorePrivate/Tests/LeafCorePrivateTests/CrossPostHandshakeIntegrationTests.swift` — moat end-to-end один test (mocked Supabase + Slack + Linear with hybrid payload)

### §14.2 pgTAP tests

New file `leaf-relay/supabase/tests/190_cross_post_rls.test.sql`:
- cross_post_log SELECT denied для non-sender-non-recipient
- cross_post_log SELECT allowed для sender
- cross_post_log SELECT allowed для recipient
- cross_post_log INSERT denied для anon
- cross_post_log INSERT allowed для service_role (Edge Function path)
- (3 more for expires_at + retention_purge expectations)

NOTE: `direct_messages.cross_post` JSONB UPDATE RLS assertions are
intentionally NOT in §14.2 — per §5.2 the `cross_post` JSONB stays
unused in S6 (cross_post_log is authoritative). Future denormalization
track will own those assertions.

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

- **Alternatives analysis (this spec's brainstorm audit)**: `docs/superpowers/specs/2026-05-16-track-5-S6-cross-post-alternatives.md` — 17 design areas with 2-4 options each, trade-offs + recommendations
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
T3: `slack_post` Edge Function real body (hybrid payload, Retry-After capture) + Deno test
T4: `linear_create_issue` Edge Function real body (idempotency key, GFM description) + Deno test
T5: `LinearScopesService` actor + tests (LeafCore)
T6: `LinearOAuthEndpoints.scope` bump to **"read,issues:create"** (narrower than `write` per A3) + endpoint tests
T7: `SupabaseClient+CrossPost` extension (`triggerSlackPost` + `triggerLinearCreate` with idempotencyKey) + tests
T8: `CrossPostPayloadBuilder` (hybrid Slack JSON dict + Linear GFM description; NO sender prefix) + payload tests + leakage sentinel fence (JSON tree walk)
T9: `LinearUsersResolver` actor (fuzzy assignee resolution; viewer.users fetch + 5min cache + exact→contains match) + `LinearGraphQLProvider.fetchAccessibleUsers` method + tests
T10: `DirectMessageService.send(...)` extension с cross-post params (idempotencyKey, retryAfter capture, parallel async let) + tests
T11: `SlackChannelsReader` + `LinearTeamsReader` + `LinearScopesReader` @Observable wrappers (fetch-on-connect + lazy refresh) + tests
T12: `SendDirectMessageSheet` UI: ChannelsPickerSection + 🔓 banner + scope-missing inline banners + assignee-unresolved notice + body textarea @-mention hint + send confirmation status rows (с retry-after surface)
T13: Composition wiring in LeafApp + `current-state.md` update + manual smoke checklist

13 atomic tasks, ~13-16 commits expected (precedent S5: 13 commits including Stage 6 fix-bundle).
