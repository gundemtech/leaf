# Track 5 — Collaboration Redesign Contract

**Status:** Draft (2026-05-13). Promoted to "Active" after first sub-phase (S1) spec is reviewed against it.
**Owners:** Authors of S1–S8 sub-phase specs.
**Audience:** Anyone writing a spec for any sub-phase of Track 5, plus future tracks that consume the multi-workspace substrate (e.g. team-tier billing).

---

## 1. Purpose & status

This document is a **reference contract**, not an implementation plan. Track 5 ("collaboration redesign") decomposes into 8 sub-phases (S1–S8); each owns its own design + plan; this contract fixes the constants between them so a choice in one sub-phase does not surprise another.

**Track 5 transforms the team experience** from "static org with members + manual invite handshake" into a **real-time collaboration surface**: persistent direct messaging (handoff / task / ping), auto-shared activity feed (commits / decisions / blockers from team members), cross-posting to Slack / Linear, push notifications, multi-workspace support, and a unified Team UI built on Track 2 D1 design system. All while preserving the E2E privacy invariant (encrypted relay, untrusted server).

**Track 5 scope is intentionally broad** — it ships the missing collaboration surface that turns Leaf from "personal memory + read-only team presence substrate" into "team memory that teammates actively send context through." This is the primary "Sprint 2 — Team E2E" feature stack per [whitepaper roadmap](../../../../leaf-docs/docs/reference/decisions.md).

**Out of Track 5 scope:**

- Per-recipient share rules (all-or-nothing per source for MVP — defer to Track 6).
- Time-bounded sharing with countdown (Share Controls forever-only for MVP).
- Share Controls presets ("Default team" / "Privacy-paranoid" / "Pair-programming").
- Audit log syncing between members.
- Stripe billing UI (separate track, post-launch).
- Workspace switcher polish for >5 workspaces.
- Slack-bot / VS Code / CLI surfaces (separate Sprint 3 tracks).
- Direct message search / archival / pinning (post-MVP).

Whitepaper (`leaf-docs`, v0.1-beta) remains source of truth for public-facing product decisions. Implementation moat (exact crypto envelope bytes, HKDF info strings, RLS policy SQL bodies, APNs payload shape) lives in `LeafCorePrivate` or `leaf-relay` (private repo), not here.

This is a **living document.** Amendments over Track 5 lifetime are expected.

---

## 2. Goal — fitness function

Track 5 is **done** when the following use cases work end-to-end between two macOS devices (Anton's Mac + Dmitrii's Mac), both running production-signed Leaf builds with multi-workspace support and Supabase relay:

| # | Use case | Acceptance criterion |
|---|---|---|
| **UC-T5-1** | **Magic-link invite.** Admin in Mac A clicks `+ Add member`, copies link, sends via any channel; invitee in Mac B clicks link → Leaf activates → modal "Join `<workspace>` team?" → click `Join` → joined. | E2E handshake completes without manual OTP entry. 6-digit OTP exists as **opt-in** for paranoid mode (admin can toggle "Require OTP for this link"). |
| **UC-T5-2** | **Auto-share + AI query.** Mac A user (Anton) toggles in Settings → Share `Git commits ON`, `Linear issues ON`, `Detected decisions ON`. Mac A user commits / closes Linear issues / Slack-detected decisions arrive. Mac B user (Dmitrii) in Cursor / Claude Code asks `что Антон делал сегодня?` → AI client invokes `leaf_query_team(member="anton")` MCP tool → reads Mac B local mirror → returns structured timeline of Mac A activity (filtered by Mac A's Share rules). | End-to-end latency ≤30s from event capture to mirror appearance. Mac B's local DB stores mirror events with sender attribution. Mirror events retain Track 1 detector output (decisions / blockers / open questions). |
| **UC-T5-3** | **Direct message — Handoff.** Mac A user opens Team tab → clicks sticky `Send` → modal: To=Dmitrii / Type=Handoff / Message="Закончил OAuth, проверь PR #142" / Attach=PR #142 → Send. Mac B receives APNs push within 5s; click on banner opens Leaf scrolled to handoff card in Team feed; reply inline. | APNs push delivery ≤5s on warm app; ≤30s if app cold. Reply appears in Mac A feed under the parent handoff card (threading). Direct message lifecycle: unread → read (auto on view) → replied (optional). |
| **UC-T5-4** | **Direct message — Task with Linear cross-post.** Mac A user sends Type=Task / Message="SSH keys в Onboarding" / Channels=☑ Leaf + ☑ Linear (LEAF project). Mac B receives push; clicks `Mark done` after completing work; Linear issue closes. Mac A sees task strikethrough + green border + "Done by Dmitrii · 18:42". | Linear issue created with `assignee=dmitrii`. Task state machine: open → acknowledged (auto on read) → done. Cross-post failure (Linear API 4xx) shows toast in sender's app; Leaf-side message persists regardless. |
| **UC-T5-5** | **Cross-post — Slack.** Mac A user sends Handoff with Channels=☑ Leaf + ☑ Slack (#leaf-architecture). Mac B sees parallel Slack message from Anton in #leaf-architecture (posted via Anton's OAuth token + `chat:write` scope). Dmitrii replies in Slack with 👍 reaction → Layer B Slack collector on Mac A captures it → appears in Mac A's Team feed as a related event. | Slack message posted via `chat.postMessage` API. UI warning shown in Send sheet: "🔓 Slack will see this message — outside E2E". Inbound reactions captured automatically (no new pipe required). |
| **UC-T5-6** | **Multi-workspace switcher.** Mac A user is in 2 workspaces (Гундем + ClientCorp). Sidebar bottom shows both with avatar + name + unread badge. Click switches active workspace; Team tab feed updates; notifications labelled `[ClientCorp]`. | Each workspace has independent teamKey + members + feed + Share rules. Switching is local-only (no network round-trip). Notification from inactive workspace appears with workspace label. |
| **UC-T5-7** | **Tier gate.** Free-tier user (no active Team subscription) opens Team tab → sees `Upgrade to Team — $30/seat (min 2)` CTA + read-only preview of feed mockup. Cannot send messages, create workspaces, or accept invites. Existing solo features (Home / Connections / Settings) remain fully functional. | Free-tier check happens at workspace-creation time and message-send time, not at per-event-capture level. Free-tier user can still receive invite links but acceptance prompts upgrade flow. |

Each sub-phase spec lists which use cases it unblocks and writes integration tests against that mapping.

**Why these 7 UCs.** They cover the four product axes — collaboration substrate (UC-T5-1, UC-T5-3), shared memory consumption (UC-T5-2), inter-tool reach (UC-T5-4, UC-T5-5), workspace flexibility (UC-T5-6), monetization (UC-T5-7). If any UC misses acceptance, Track 5 is not done.

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Mac A (sender)                                                       │
│  ┌────────────────┐   ┌─────────────────┐   ┌─────────────────────┐  │
│  │ Capture / UI   │──▶│ Share-rule      │──▶│ Outbox encrypt      │  │
│  │ (commits,      │   │ filter          │   │ (teamKey AES-GCM)   │  │
│  │  Linear, Slack,│   │ (per-source     │   │                     │  │
│  │  detections,   │   │  toggles)       │   │                     │  │
│  │  Send sheet)   │   │                 │   │                     │  │
│  └────────────────┘   └─────────────────┘   └──────────┬──────────┘  │
└──────────────────────────────────────────────────────────│───────────┘
                                                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Supabase (untrusted relay)                                          │
│  ┌────────────────────┐  ┌──────────────────┐  ┌─────────────────┐   │
│  │ Encrypted blobs    │  │ Postgres + RLS   │  │ Edge Functions  │   │
│  │ - team_events      │  │ (per-workspace   │  │ - APNs gateway  │   │
│  │ - direct_messages  │  │  isolation)      │  │ - invite resolve│   │
│  │ - invites          │  │                  │  │ - cross-post    │   │
│  │ - workspace_keys   │  │ Realtime WS      │  │   to Slack/     │   │
│  │                    │  │ broadcast        │  │   Linear        │   │
│  └────────────────────┘  └──────────────────┘  └─────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
                                                           │
                                                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Mac B (recipient)                                                   │
│  ┌────────────────┐   ┌─────────────────┐   ┌─────────────────────┐  │
│  │ Pull loop      │──▶│ Decrypt         │──▶│ Local mirror DB     │  │
│  │ (WebSocket +   │   │ (teamKey from   │   │ (events from        │  │
│  │  periodic      │   │  Keychain)      │   │  Anton labelled     │  │
│  │  poll)         │   │                 │   │  sender_pubkey=...) │  │
│  └────────────────┘   └─────────────────┘   └──────────┬──────────┘  │
│                                                        ▼              │
│                              ┌──────────────────────────────┐         │
│                              │ Team UI / MCP / Notifications│         │
│                              │ (reads mirror DB)            │         │
│                              └──────────────────────────────┘         │
└──────────────────────────────────────────────────────────────────────┘
```

**Existing Cloudflare Workers + Durable Objects relay** (`oauth.gundem.tech/v1/invite/*` + `/v1/key-rotation/*`) **stays operational** until Track 5 migration completes. New features (long-term encrypted storage, direct messages, magic-link invites, APNs gateway) go on Supabase from day one. After Track 5 ship + smoke verification, Cloudflare invite/rotation endpoints are deprecated in a follow-up Track 6 cleanup.

---

## 4. Sub-phase decomposition

8 sub-phases, mostly sequential due to schema dependencies. Each sub-phase = its own brainstorm-session per `conventions.md` 8-stage workflow → its own spec → its own implementation plan → its own feature branch.

**Sub-phase naming convention:** `S1` / `S2` / ... `S8` (Track 5 sub-phases — using `S` to match Track 4 convention). Spec filename: `docs/superpowers/specs/YYYY-MM-DD-track-5-SN-<topic>.md`.

```
   ┌─────────────────────────────────────────┐
   │  S1 — Backend Foundation                │   sequential, foundation
   │  Supabase project + tables + RLS +      │
   │  Edge Functions skeleton (APNs gateway, │
   │  invite resolver, cross-post)           │
   └────────────┬────────────────────────────┘
                ▼
   ┌─────────────────────────────────────────┐
   │  S2 — Multi-workspace Substrate         │   sequential, breaking change
   │  Schema rewrite OrgService single →     │
   │  multi-tenant. workspaces table +       │
   │  per-workspace teamKey + Keychain       │
   │  multi-key support                      │
   └────────────┬────────────────────────────┘
                ▼
   ┌─────────────────────────────────────────┐
   │  S3 — Magic-Link Invite                 │   sequential, depends on S1+S2
   │  Magic-link generation + Supabase       │
   │  invite resolver + deep-link routing +  │
   │  opt-in OTP for paranoid mode           │
   └────────────┬────────────────────────────┘
                ▼
   ┌─────────────────────────────────────────┐
   │  S4 — Direct Messages Primitive         │   sequential
   │  message_id schema + Send sheet UI +    │
   │  APNs push delivery + lifecycle         │
   │  (unread → read → replied/done) +       │
   │  3 templates (Handoff/Task/Ping)        │
   └────────────┬────────────────────────────┘
                ▼
   ┌─────────────────────────────────────────┐
   │  S5 — Auto-Share Substrate              │   sequential, depends on S4
   │  Share Controls UI (Settings) +         │
   │  broadcast loop in Agent +              │
   │  mirror writer on recipient side +      │
   │  retention scheduler (30d auto-shared,  │
   │  forever direct messages)               │
   └────────────┬────────────────────────────┘
                ▼
   ┌─────────────────────────────────────────┐
   │  S6 — Cross-Post Slack + Linear         │   sequential, depends on S4
   │  Write scope-bumps (chat:write,         │
   │  Linear write) + Edge Functions for     │
   │  outbound post + Linear Task creation + │
   │  UI Channels multi-select in Send sheet │
   └────────────┬────────────────────────────┘
                ▼
   ┌─────────────────────────────────────────┐
   │  S7 — Team UI Redesign + Multi-Workspace│   depends on S2+S4+S5+S6
   │  Unified feed + filter chips + pill-row │
   │  members + sticky Send + 3 empty states │
   │  + workspace switcher in Sidebar bottom │
   │  + Organization view removed → Settings │
   └────────────┬────────────────────────────┘
                ▼
   ┌─────────────────────────────────────────┐
   │  S8 — Polish + Settings Restructure     │   sequential, closes track
   │  Notifications config UI +              │
   │  Settings → Workspace (members admin,   │
   │  name) + Privacy section (read-only     │
   │  deny-list) + MCP leaf_query_team tool +│
   │  tier-gating (Free vs Team CTA)         │
   └─────────────────────────────────────────┘
```

| Sub-phase | Sequential dep | Owner-side responsibility |
|---|---|---|
| **S1** Backend Foundation | none | Local Claude (Mac) writes Supabase schema migrations + Edge Function scaffolding. VPS Claude (if needed) deploys / configures Supabase project. |
| **S2** Multi-workspace Substrate | S1 (writes Supabase schema) | Local Claude — Swift schema rewrite + GRDB migrations + Keychain multi-key support. Tests on local SPM. |
| **S3** Magic-Link Invite | S1 + S2 | Local Claude — Swift invite UI + handshake. VPS Claude — Supabase Edge Function for invite token resolution. |
| **S4** Direct Messages Primitive | S2 (needs workspace_id) | Local Claude end-to-end (Swift UI + APNs setup via Supabase Edge Function). |
| **S5** Auto-Share Substrate | S4 (uses same outbound encrypt loop) | Local Claude — Swift broadcast loop + mirror reader + retention scheduler + Share Controls UI. |
| **S6** Cross-Post Slack + Linear | S4 | Local Claude — OAuth scope-bump UX + Send sheet Channels multi-select. VPS Claude — Edge Function for outbound API call (Slack/Linear). |
| **S7** Team UI Redesign + Multi-Workspace | S2 + S4 + S5 + S6 | Local Claude (Swift UI). Track 2 D1 design system reused as substrate. |
| **S8** Polish + Settings Restructure | S5 + S7 | Local Claude. |

**Why S6 in parallel-feel position despite sequential dep on S4.** S6 reuses S4's encrypted message envelope as cross-post payload — needs the message-primitive shape. But S6 doesn't block S5 / S7 / S8 in terms of code paths — only data flow. A specific sub-phase spec can argue for parallelism within Track 5 if implementation evidence supports.

**Sub-phase smoke tests.** Each sub-phase ships a manual smoke checklist (per `conventions.md` 8-stage workflow Stage 7) **before** merge. Acceptance gate for Track 5 as a whole = all 7 UCs from §2 passed manually on two real Macs (Anton + Dmitrii).

---

## 5. Schema changes — overview

Sub-phase specs own exact migration content; this is the cross-phase shape.

### 5.1 Supabase tables (new infrastructure)

| Table | Owner phase | Purpose |
|---|---|---|
| `workspaces` | S1 | `(id uuid PK, name text, created_by_pubkey text, created_at timestamptz)`. Top-level entity replacing single-tenant `org`. |
| `workspace_members` | S1 | `(workspace_id uuid FK, pubkey text, display_name text, joined_at timestamptz, removed_at timestamptz NULL)`. Membership graph. |
| `workspace_keys` | S1 | `(workspace_id uuid FK, key_id uuid, ecdh_wrap bytea, recipient_pubkey text, posted_at timestamptz, ack_at timestamptz NULL)`. ECDH-wrapped teamKey distribution. Replaces Cloudflare DO state. |
| `team_events` | S1 | `(workspace_id uuid FK, event_id uuid, sender_pubkey text, encrypted_payload bytea, kind text, created_at timestamptz, expires_at timestamptz NULL)`. Long-term encrypted event storage (30d retention via `expires_at`). |
| `direct_messages` | S1 | `(workspace_id uuid FK, message_id uuid, sender_pubkey text, recipient_pubkey text, kind text [handoff/task/ping], encrypted_payload bytea, cross_post jsonb, created_at, read_at NULL, done_at NULL, done_by_pubkey NULL, reply_to uuid NULL)`. Forever retention; soft-delete via column. |
| `invites` | S1 | `(token uuid PK, workspace_id uuid FK, admin_pubkey text, encrypted_teamkey bytea, expires_at, require_otp bool, otp_hash text NULL, claimed_at NULL, claimed_by_pubkey NULL)`. Magic-link invite resolution. |
| `apns_tokens` | S1 | `(pubkey text, apns_token text, device_id text, updated_at)`. APNs device-token registry per-pubkey. |
| `cross_post_log` | S1 | `(message_id uuid FK, channel text [slack/linear], external_ref text, posted_at, error_text text NULL)`. Outbound audit for retry / debug. |
| `pubkey_registry` | S1 | `(pubkey text PK, auth_id uuid FK → auth.users, display_name text, registered_at timestamptz)`. Maps Supabase Auth user id ↔ Leaf X25519 pubkey. Required for Auth Hook to emit `pubkey` JWT custom claim used in all other tables' RLS policies. |

> **Amendment 2026-05-14 (S1 spec):** §5.1 extended with `pubkey_registry` table. Reason: Supabase Auth issues opaque `auth.uid()`; all other tables' RLS policies reference Leaf-side `pubkey`. The Auth Hook function (`get_pubkey_for_auth_id`) requires an `auth_id ↔ pubkey` lookup table to emit the custom JWT claim. Discovered during S1 implementation — was implicit in contract §5.2 RLS pseudocode (`auth.jwt() ->> 'pubkey'`) but the mapping table was unnamed. Living-doc process per §18.

### 5.2 Supabase RLS (Row-Level Security) policies

Per-workspace isolation enforced server-side. Pseudocode (full SQL in S1 spec):

```sql
-- Authenticated user can see only events for workspaces they're members of
CREATE POLICY team_events_read ON team_events FOR SELECT
  USING (workspace_id IN (
    SELECT workspace_id FROM workspace_members
    WHERE pubkey = auth.jwt() ->> 'pubkey' AND removed_at IS NULL
  ));

-- Direct messages: sender or recipient only
CREATE POLICY direct_messages_read ON direct_messages FOR SELECT
  USING (sender_pubkey = auth.jwt() ->> 'pubkey'
      OR recipient_pubkey = auth.jwt() ->> 'pubkey');
```

Supabase JWT custom claim `pubkey` set during invite acceptance (S3 spec details).

### 5.3 SQLCipher (on-device) schema changes

| Table | Change | Owner phase |
|---|---|---|
| `org` → `workspaces` | Rename + add `workspace_id` PK column. Migration: existing single `org` row → first workspace. | S2 |
| `team_members` | Add `workspace_id` FK column. Backfill with first workspace id. | S2 |
| `team_keys` | Add `workspace_id` FK column. | S2 |
| `presence_outgoing`, `presence_history` | Add `workspace_id` FK column. | S2 |
| `messages_mirror` | **NEW** table — `(message_id PK, workspace_id FK, sender_pubkey, recipient_pubkey, kind, decrypted_payload_json, created_at, read_at, done_at, reply_to)`. Local mirror of `direct_messages` from Supabase. | S4 |
| `team_events_mirror` | **NEW** table — `(event_id PK, workspace_id FK, sender_pubkey, kind, decrypted_payload_json, created_at)`. Local mirror of auto-shared events from teammates. | S5 |
| `share_rules` | **NEW** table — `(workspace_id FK, source_kind text [git/linear/slack/decision/blocker/...], enabled bool, updated_at)`. Per-source toggles. | S5 |
| `apns_token_local` | **NEW** singleton table for current device APNs token storage (before push to Supabase). | S4 |

### 5.4 Migrations

- **M019** — `org` → `workspaces` rename + workspace_id FK additions (S2).
- **M020** — `share_rules` table (S5).
- **M021** — `messages_mirror` table (S4).
- **M022** — `team_events_mirror` table (S5).
- **M023** — `apns_token_local` table (S4).

Supabase migrations: managed via `supabase/migrations/*.sql` (separate from on-device GRDB migrations).

---

## 6. Privacy model

Track 5 maintains the **E2E invariant** for Leaf-internal data while introducing **explicit outbound flows** (cross-post Slack/Linear) that exit the E2E boundary by user opt-in.

| Flow | E2E? | Notes |
|---|---|---|
| Direct messages (within Leaf) | ✅ Yes | Encrypted with workspace teamKey. Supabase sees only ciphertext + recipient_pubkey. |
| Auto-shared events (within Leaf) | ✅ Yes | Same teamKey. Recipients build local mirror by decrypting. |
| APNs push notification body | ⚠️ Title only | APNs sees notification title (e.g., "Anton sent a handoff"). Body content NOT included in APNs payload — recipient app fetches encrypted message after wake. |
| Invite handshake | ✅ Yes | Magic-link contains admin's pubkey + workspace_id; invitee derives ECDH shared secret, decrypts teamKey wrapped under it. Supabase sees ciphertexts. |
| Cross-post to Slack | ❌ No (explicit opt-in) | Message text sent via `chat.postMessage` API in **plain**. UI shows 🔓 warning in Send sheet next to Slack checkbox. |
| Cross-post to Linear | ❌ No (explicit opt-in) | Same — Task text sent to Linear issue body. UI shows 🔓 warning. |
| Layer B capture of Slack reply / reaction | ❌ No (existing behavior) | Already in Layer B — Slack API plaintext capture. Not a Track 5 regression. |

**Default deny-list** (read-only in v0.1-beta UI per whitepaper) stays the architectural ban:

- `.env*`, `.git/config`, `.aws/credentials`, `.ssh/*`
- Files > 100MB
- AI prompt/response content (ADR-010 absolute ban)

This applies at the **source filter** layer (S5 spec) — events matching deny-list are dropped before encryption, never reach Supabase. Cross-post inherits same filter: a Send sheet message referencing `.env` content (in attached event or message body) is blocked client-side.

---

## 7. UI surface contract

Track 2 D1 design tokens are the **only** visual primitive source. No hardcoded colors / spacing / typography in Track 5 code. Specific token mapping:

| Surface | Token |
|---|---|
| Direct message border accent (all 3 types) | `LeafColor.accent.primary` (differentiation via icon + label, not color) |
| Decision card accent | `LeafColor.status.success` |
| Blocker card accent | `LeafColor.status.warning` |
| Raw activity row (commit / Linear update / Slack mention) | `LeafColor.text.tertiary` icon + default `LeafColor.surface.canvas` |
| Cross-post warning ("🔓 Slack will see this") | `LeafColor.status.warning` background tint |
| Unread badge on workspace pill | `LeafColor.accent.emphasis` |

Components reused: `LeafCard.raised` (feed cards), `LeafSection` (Team-screen sections), `LeafBanner.danger` (removed-from-workspace), `LeafButton.primary` / `LeafButton.secondary` (CTAs), `LeafEmptyState` (3 empty states).

New atoms required (defer exact spec to S7):
- `LeafMessageCard` — direct message card with kind icon + accent border + inline actions.
- `LeafFeedRow` — compact raw activity row.
- `LeafWorkspaceSwitcher` — sidebar bottom workspaces list.
- `LeafFilterChips` — chip row above feed.

---

## 8. Direct messages primitive (S4 contract)

S4 spec must cover all of these. Anything dropped from S4 is dropped permanently from Track 5, not deferred.

### 8.1 Three template types

| Type | Icon | Lifecycle | Notification copy |
|---|---|---|---|
| **Handoff** (🤝) | `figure.run.motion` or similar SF Symbol | unread → read (auto on view) → replied (optional) | "`<sender>` handed off: `<excerpt>`" |
| **Task** (☑) | `checklist` | open → acknowledged (auto on read) → done (manual mark) | "`<sender>` assigned task: `<excerpt>`" |
| **Ping** (🔔) | `bell` | unread → read (auto-dim on view) | "`<sender>`: `<excerpt>`" |

Type is **fixed at send time** — cannot change later. Lifecycle states map to `read_at` / `done_at` columns on `direct_messages` table.

### 8.2 Send sheet fields

- **To** — dropdown of workspace members (excluding self).
- **Type** — segmented control Handoff / Task / Ping (one required).
- **Message** — text area, no length limit (encrypted before send).
- **Attach event** — optional picker over recent local events (commits / PRs / Linear issues). Attached event encoded as `(kind, external_ref)` in encrypted_payload — not the full event body.
- **Channels** — multi-select: ☑ Leaf (default, always checked) + ☐ Slack (channel picker) + ☐ Linear (Task type only, project picker). Cross-post chans render warning chip "🔓".
- **Notify** — toggle (default ON). Disables APNs push but message still arrives in recipient feed.

### 8.3 Task reminders

If a Task message has `done_at IS NULL` and `created_at < now() - 24h`:
- Supabase Edge Function runs daily cron job (`task_reminders_cron`).
- Sends fresh APNs push to recipient: "Task still open: `<excerpt>`".
- One reminder per task, no retry beyond first 24h check.
- User can disable in Settings → Notifications → Task reminders toggle.

### 8.4 Threading

`reply_to uuid NULL` column on `direct_messages` enables threaded replies. UI renders reply chain inline under parent message (1-level deep MVP, no nested threading).

---

## 9. Cross-post outbound integrations (S6 contract)

### 9.1 Slack

- **Scope-bump.** Existing Slack OAuth scope `read` extended to include `chat:write` (already public via Track 3 D3 scope-bump UX — reuses substrate).
- **API call.** `POST /api/chat.postMessage` from Supabase Edge Function (sender's stored Slack token forwarded; never proxied through Leaf company servers in plaintext beyond Edge Function memory).
- **Message body.** `<sender_name>: <message_text>\n\n[Sent via Leaf]\n<optional attached event link>`.
- **Channel picker.** Send sheet dropdown queries `conversations.list` (cached for session).

### 9.2 Linear

- **Scope-bump.** Existing Linear OAuth scope `read` extended to include `write`.
- **API call.** `POST /api/graphql` mutation `issueCreate` from Supabase Edge Function with sender's Linear token.
- **Task → Linear issue mapping.** Title = first 80 chars of message; description = full message; assignee = recipient's Linear ID (resolved via `usersByEmail` or pre-stored `linear_user_id` per workspace member); project = picked in Send sheet.
- **Bi-directional state.** When Linear issue closes (captured via existing Layer B Linear collector), Mac A's Leaf updates corresponding `direct_messages.done_at`. Detection logic: encrypted_payload includes `linked_linear_id` field, mirror reader links events on receive.

### 9.3 Cross-post failure handling

- Edge Function returns 4xx/5xx → `cross_post_log.error_text` populated → sender's Leaf shows toast "Slack post failed: <reason>".
- Leaf-internal message **persists regardless** — cross-post is best-effort secondary delivery.
- Retry: no automatic retry in MVP. Sender can manually `Resend to Slack` from message context menu.

---

## 10. Notifications (S8 contract)

### 10.1 APNs setup

- Supabase Edge Function `apns_push` handles APNs token registry + push delivery.
- Apple Push Notification credentials (.p8 key) stored in Supabase secrets, never in client code.
- Each device registers APNs token on app launch → POST to `apns_tokens` table keyed by pubkey + device_id.
- Multi-device support: same pubkey can have multiple APNs tokens (Mac at home + Mac at office); push fanout sends to all active devices.

### 10.2 Default notification settings

Per design decision (see notifications brainstorm 2026-05-13):

| Type | Default | Locked? |
|---|---|---|
| Direct messages — Handoff | ON | ✅ Yes (cannot disable) |
| Direct messages — Task | ON | No |
| Direct messages — Ping | ON | No |
| Auto-detected — Decision | ON | No |
| Auto-detected — Blocker | ON | No |
| Auto-detected — Open Question | OFF | No |
| Auto-detected — Where Stopped | OFF | No |
| Raw activity — Commit / Linear / Slack mention | OFF | No |
| Behavior — Respect macOS Focus mode | ON | No |
| Behavior — Coalesce 3+/5min into single push | ON | No |
| Behavior — Sound on direct messages | ON | No |

### 10.3 Notification payload shape

Per privacy invariant (§6), APNs payload contains **title only** (no body excerpt):

```json
{
  "aps": {
    "alert": { "title": "Anton sent a handoff" },
    "sound": "default",
    "thread-id": "<workspace_id>"
  },
  "leaf_message_id": "<uuid>",
  "leaf_workspace_id": "<uuid>"
}
```

App on receive: wake → fetch encrypted message from Supabase by `leaf_message_id` → decrypt → display in feed.

---

## 11. Share Controls (S5 contract)

### 11.1 Settings → Share UI

Per design decision (variant A "Minimum"):

- **Sources section.** Per-source toggle ON/OFF for: Git commits, Linear issues, Slack mentions, GitHub PRs, Detected decisions, Detected blockers, Detected open questions, Detected where-stopped, Raw GitHub activity (stars, watches, etc.).
- **Default state.** Git / Linear issues / Detected decisions / Detected blockers ON. Others OFF.
- **Never shared (read-only).** Static list rendered as `LeafCard.warning` showing default deny-list patterns.
- **Per-recipient / time-bounded / presets — NOT in S5 scope.** Marked as "Coming in v1.1" placeholder text.

### 11.2 Share-rule application

S5 broadcast loop reads `share_rules` table on every emit:

```
event captured
  ├─ check default deny-list (file path / file size / event_kind)
  │     → if match: drop, do not encrypt
  ├─ check share_rules.enabled for event's source_kind
  │     → if disabled: drop
  └─ encrypt with workspace teamKey → POST to Supabase team_events
```

**No partial events.** A `commit` event matching deny-list (e.g., file path contains `.env`) is dropped **entirely** — not partially redacted. Privacy invariant: no leaky filtering.

---

## 12. Invite flow (S3 contract)

### 12.1 Magic link generation

Admin clicks `Invite` → Leaf generates:
- `invite_token` (uuid, random 128 bits)
- `admin_pubkey_bundle` (admin's X25519 pubkey + workspace_id + workspace name)
- Encrypts `teamKey` under a one-time symmetric key derived from `invite_token` (HKDF + token as salt)
- POSTs to Supabase `invites` table: `(token, workspace_id, admin_pubkey, encrypted_teamkey, expires_at = now() + 24h, require_otp = <toggle>)`

Magic link format: `leaf://invite/<token>?workspace=<name>&admin=<pubkey>` (deep-link registered for `tech.gundem.leaf`).

### 12.2 Invitee flow

- Click link → Leaf app activates → modal: "Join `<workspace_name>` team?"
- Leaf calls Supabase `invite_resolve` Edge Function with token + invitee's pubkey
- Edge Function returns `encrypted_teamkey` + `admin_pubkey` (no auth check — token itself is the auth)
- Leaf derives ECDH(invitee_priv, admin_pub) → HKDF → decryption key → decrypts teamKey
- If `require_otp = true`: modal shows OTP field, user enters 6-digit code, Leaf verifies hash matches `otp_hash` in invite row before proceeding
- Leaf inserts new workspace + teamKey into local SQLCipher
- Leaf POSTs `workspace_members` row with invitee's pubkey + display_name
- Admin's Leaf gets realtime push from `workspace_members` insert → updates pill-row UI

### 12.3 Opt-in OTP

Admin toggle in Invite modal: "Require OTP for extra security" (default OFF). When ON:
- Admin gets OTP shown after generating link
- Admin shares link + OTP via separate channels (link via iMessage, OTP via Telegram)
- Invitee must enter OTP to proceed

For default OFF case, security guarantee: link contains random 128-bit token, intercepting requires either MITM the link itself OR breaking X25519 ECDH. Same level as 6-digit OTP intercept in old flow.

---

## 13. Retention policy (S5 contract)

| Data | Retention | Owner |
|---|---|---|
| Direct messages (Supabase) | Forever (no `expires_at`) | S4 |
| Auto-shared events (Supabase) | 30 days (`expires_at = created_at + 30d`) | S5 |
| Direct messages mirror (local SQLCipher) | Forever | S4 |
| Auto-shared events mirror (local SQLCipher) | User-configurable (Settings → Privacy → "Keep last N days" default 90d) | S5 |
| Invite tokens | 24h hard expiry | S3 |
| APNs tokens | Cleared on device logout / app uninstall | S4 |
| Cross-post log | 30 days (debug only) | S6 |

Retention cleanup: Supabase cron job `retention_purge` runs daily, deletes rows where `expires_at < now()`. On-device mirror cleanup: GRDB scheduled job (Agent process) runs daily.

---

## 14. Multi-workspace (S2 + S7 contract)

### 14.1 Data model

- One Mac device = N workspaces simultaneously (no limit in MVP).
- Each workspace = independent teamKey stored as **file under `~/Library/Application Support/Leaf/keystore/workspaces/<workspace_uuid>/team-keys/<key_id>.key`** (0o600 perms). Per-workspace isolation enforced via filesystem path scoping; cross-workspace read fails by path. M019 includes a one-time relocation from legacy `~/Library/Application Support/Leaf/keystore/team-keys/` layout for alpha.x upgrade compatibility.
- All on-device tables (`team_events_mirror`, `direct_messages_mirror`, `share_rules`, `team_members`) have `workspace_id` FK.
- "Active" workspace = persistent UI state, stored in `UserDefaults.active_workspace_id`.

> **Amendment 2026-05-14 (S2 spec):** §14.1 teamKey storage moved from Keychain to file-based per-workspace layout. Reason: Keychain `kSecAttrAccount=leaf_team_key_<uuid>` scope is global per-bundle-id, making per-workspace isolation depend on naming discipline rather than OS-enforced boundaries; file-based path scoping is OS-enforced and trivially auditable (`find ~/Library/Application\ Support/Leaf/keystore/workspaces -type d`). Detailed rationale: `2026-05-14-track-5-S2-multiworkspace-substrate.md` §8.3. Living-doc process per §18.

### 14.2 Switcher UI

- Sidebar bottom: vertical list of workspaces, each row = avatar + name + unread badge + active indicator.
- Click row → switch active workspace → Team / Connections / Settings tabs re-render with new context.
- `+ Add workspace` button at bottom of list → opens onboarding flow.
- Right-click context menu: Rename / Leave / Mark all read.

### 14.3 Notifications across workspaces

- APNs push from inactive workspace shows label `[<workspace_name>]` prefix in notification title.
- Notification click → opens app to that workspace's Team tab.

---

## 15. Tier-gating (S8 contract)

### 15.1 Tier check

- Free tier — solo + read-only Team preview.
- Team tier — full Track 5 functionality.
- Tier state stored in `UserDefaults.tier` (cached) + verified server-side via Supabase JWT custom claim on workspace creation / message send.

### 15.2 Free-tier behavior

- Team tab visible but feed shows mockup-style preview + sticky CTA "Upgrade to Team — $30/seat (min 2)".
- `+ Create workspace`, `+ Add member`, `+ Send` actions disabled, click shows upgrade modal.
- Invite link acceptance: invitee can accept (becomes part of workspace), but workspace owner pays for seats. If owner downgrades, workspace becomes read-only for all.

### 15.3 Upgrade flow

- Click CTA → opens Stripe Checkout (handled by separate billing track post-launch — for MVP this opens a placeholder modal "Stripe billing coming soon — early access? <email>").
- Email captured for waitlist.

---

## 16. Open questions

Track 5 sub-phases or future tracks resolve these:

| OQ | Question | Sub-phase that decides |
|---|---|---|
| **OQ-T5-1** | Stripe integration scope — separate track or S8? | S8 spec or post-S8 |
| **OQ-T5-2** | Workspace leave flow — does data wipe locally or remain read-only? | S2 spec |
| **OQ-T5-3** | Linear assignee resolution when invitee hasn't connected Linear yet | S6 spec |
| **OQ-T5-4** | APNs Voip-style for instant wake vs. standard push (cold-start latency) | S4 spec |
| **OQ-T5-5** | Workspace name uniqueness — globally or per-admin? | S1 spec |
| **OQ-T5-6** | Free-tier invite-acceptance UX — block, allow but downgrade, allow but trial? | S8 spec |
| **OQ-T5-7** | Old Cloudflare invite/rotation endpoints — sunset timeline + migration strategy for existing users | Post-Track 5 (Track 6 cleanup) |
| **OQ-T5-8** | Search/archival/pinning in feed — post-MVP track? | Post-Track 5 |
| **OQ-T5-9** | Slack message edit/delete sync — if sender edits handoff in Leaf, does cross-posted Slack message update? | S6 spec |

---

## 17. Local vs VPS responsibilities

Per `feedback_local_vs_vps_claude_split.md` discipline:

| Sub-phase | Local Claude (Mac) | VPS Claude / DevOps |
|---|---|---|
| **S1** Backend Foundation | Write Supabase migration SQL, Edge Function TypeScript scaffolds | Deploy Supabase project, configure secrets (Apple .p8 key, Slack/Linear OAuth), set up DNS for `<workspace>.leaf.gundem.tech` (if needed) |
| **S2** Multi-workspace | Swift schema + GRDB migrations + Keychain handling | n/a |
| **S3** Magic-link Invite | Swift invite UI + handshake logic | Deploy `invite_resolve` Edge Function, configure deep-link domain |
| **S4** Direct Messages | Swift Send UI + APNs registration + lifecycle | Deploy `apns_push` Edge Function, configure APNs key in Supabase secrets |
| **S5** Auto-Share | Swift broadcast loop + Share Controls UI + mirror reader | Deploy `retention_purge` cron, monitor Supabase storage |
| **S6** Cross-Post | Swift Channels UI + OAuth scope-bump | Deploy `slack_post` + `linear_create_issue` Edge Functions |
| **S7** Team UI | Swift UI only | n/a |
| **S8** Polish | Swift Settings + tier-gating + MCP tool | Configure Stripe webhooks (if S8 includes), monitor production |

---

## 18. Living document

Track 5 contract is **expected to be amended** during sub-phase implementation as field-level details surface. Amendment process:

1. Sub-phase spec identifies a contract conflict / gap.
2. Sub-phase author proposes amendment inline in this contract document with `> **Amendment YYYY-MM-DD (SN spec):**` annotation.
3. Local Claude commits amendment alongside sub-phase spec.
4. Other sub-phase specs reference the updated section by date.

Examples from precedent: Track 1 contract §5.2 `sessions` extension → `where_stopped_log` (Track 1 D3 spec).

---

## 19. Whitepaper sync

Whitepaper sync required at Track 5 ship (per `CLAUDE.md` whitepaper rules):

- `docs/team-sharing/share-controls.md` — update with v0.1-beta MVP scope (minimum per-source toggles, deferred recipients + time-bounded).
- `docs/team-sharing/index.md` — add direct messages as native Team feature (currently doesn't mention).
- `docs/surfaces/native-app.md` — update Team section description from "presence grid + shared events" to match shipped UI (unified feed + direct messages + multi-workspace).
- `docs/reference/decisions.md` — record team-collaboration architecture decisions if any new ones surface (currently 9 fixed; may add 10th for "multi-workspace from day one").
- `docs/reference/changelog.md` — bump entry per `leaf-docs/CLAUDE.md` rules (this is a milestone → version bump v0.1-beta → v0.2-beta).

Sync happens at end of S8, not per sub-phase, to keep public-facing docs from intermediate-state drift.

---

## 20. References

- Whitepaper v0.1-beta: `~/Desktop/Leaf/leaf-docs/docs/`
- Track 1 contract pattern: `docs/superpowers/specs/2026-05-08-track-1-detection-substrate-contract.md`
- Phase 5 architecture contract: `docs/superpowers/specs/2026-05-04-phase-5-architecture-contract.md`
- Track 2 D1 design tokens: `Leaf/Theme/Tokens/`
- Brainstorm session transcript: 2026-05-13 (current Claude session)
- Strategic decisions: `~/Desktop/Leaf/leaf-docs/docs/reference/decisions.md`
- Sprint roadmap: `~/Desktop/Leaf/leaf-internal/roadmap.yaml` (will add Track 5 node after this contract is reviewed)
