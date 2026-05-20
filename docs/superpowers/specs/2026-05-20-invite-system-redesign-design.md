# Invite System Redesign — Open / Closed Workspaces

**Status:** Draft (2026-05-20). Brainstorm-approved by Anton in chat session.
**Owner:** Local Claude (Mac).
**Branch:** TBD — implementation not yet scheduled. Spec lands first, plan + execution follow as separate phase.
**Predecessor:** Track 5 / S3 magic-link invite (current per-invitee ECDH model with mandatory bilateral Join code exchange).
**Cross-reference:**
- `fix/in-app-join-workspace-entry` — interim UX-gap fixes (in-app Join entry in Sidebar + Join code visible in Settings → Account). Superseded by this redesign but stays as bridge until shipped.
- Track 5 / S3 spec — `docs/superpowers/specs/2026-05-15-track-5-S3-magic-link-invite.md` (envelope v=1, ECDH-to-invitee model).
- Track 5 S8 spec — `docs/superpowers/specs/2026-05-19-track-5-S8-polish-settings.md` (Tier-gate substrate, notification_prefs, MVP default `tier="team"`).

---

## 1. Goal — fitness function

Workspace invite flow is **done** when:

1. **Admin sees ONE generate-invite action per workspace,** produces a token rendered as both a clickable link AND a typeable short code. Admin chooses TTL.
2. **Admin chooses workspace privacy mode at creation** (and can change later): **Open** (anyone with link/code joins instantly) OR **Closed** (anyone with link/code becomes a pending request that admin approves/declines).
3. **30-50 person team kickoff** = one link in Slack #general + admin reviews queue (closed) or zero admin work (open). **NOT** 30 bilateral Join-code round-trips.
4. **Admin's Mac online state is irrelevant** for invite acceptance in both modes. Admin can close the laptop after generating the token; invitees can still join. Closed-mode requests wait in queue until admin next opens Leaf.
5. **Link leak in closed mode** drowns admin in pending requests from outsiders BUT does not grant them access — admin filters via approve UI. Admin can revoke compromised token + generate new one.
6. **Link leak in open mode** grants team-read access to leak-receiver UNTIL admin revokes — admin accepted this trade-off when picking open mode. After revoke + team-key rotation (M009 substrate already exists), past leakers lose future-data access.
7. **TTL expiry** auto-invalidates tokens without admin action.
8. **Multiple active tokens** coexist on one workspace (admin can have separate tokens for team + contractors + vendors with different TTLs).
9. **Revoke** at any time, including before TTL.
10. **Manual smoke** (10 gates, §10 below) passes on signed two-Mac build.

---

## 2. UX walkthrough

Concrete scenarios with screen-level detail. No code, no crypto words.

### 2.1 Алина creates workspace (admin path A)

Алина opens Leaf, has no workspace yet (or wants a new one). Clicks `+ Add workspace` in Sidebar bottom.

**`WorkspaceCreateSheet` redesign:**

```
┌─────────────────────────────────────────────┐
│  Create workspace                           │
│                                             │
│  WORKSPACE NAME                             │
│  [ TestRoom                              ]  │
│                                             │
│  YOUR DISPLAY NAME                          │
│  [ Алина                                 ]  │
│                                             │
│  PRIVACY MODE                               │
│  ⦿ Closed — admin approves each new member │
│  ◯ Open — anyone with link/code joins      │
│                                             │
│  DEFAULT INVITE TTL                         │
│  [ 24 hours          ▼ ]                    │
│    1 hour                                   │
│    24 hours    ← default                    │
│    7 days                                   │
│    30 days                                  │
│    Never expires                            │
│                                             │
│  ◯ Single-use tokens by default             │
│                                             │
│         [ Cancel ]    [ Create ]            │
└─────────────────────────────────────────────┘
```

**Notes:**
- Default mode = **Closed**. More users land here expecting admin control; opt-in to open is a deliberate choice.
- Default TTL = **24 hours**. Standard for SaaS invites.
- TTL applies to NEW tokens — admin can override per-token at generation time.
- Single-use toggle is also a default for new tokens; per-token override available.
- Mode + defaults can be changed later in Settings → Workspace.

### 2.2 Алина generates invite (admin path B)

In TeamView (or Settings → Workspace → Active invite tokens), Алина clicks `+ Generate invite`.

**`GenerateInviteSheet` rewrite:**

```
┌─────────────────────────────────────────────┐
│  Generate invite                            │
│                                             │
│  TTL                                        │
│  [ 24 hours          ▼ ]                    │
│                                             │
│  ◯ Single-use (token expires after 1 use)  │
│                                             │
│  Workspace privacy mode: Closed             │
│  (Change in workspace settings)             │
│                                             │
│         [ Cancel ]    [ Generate ]          │
└─────────────────────────────────────────────┘
```

After `[Generate]`:

```
┌─────────────────────────────────────────────┐
│  Invite ready                               │
│                                             │
│  📎 LINK (copy + share via Slack/iMessage) │
│  ┌─────────────────────────────────────┐    │
│  │ leaf://invite/abc123def456...       │    │
│  └─────────────────────────────────────┘    │
│  [ Copy link ]                              │
│                                             │
│  🔢 CODE (read over phone / paste in-app)   │
│  ┌─────────────────────────────────────┐    │
│  │   LEAF-A8X7-B3K9                    │    │
│  └─────────────────────────────────────┘    │
│  [ Copy code ]                              │
│                                             │
│  ⏰ Expires in 23h 59m                       │
│  🔄 0 / unlimited uses                       │
│  🔒 Closed workspace — admin approval req'd │
│                                             │
│            [ Done ]                         │
└─────────────────────────────────────────────┘
```

**Notes:**
- ONE token, TWO renderings (link + code) — same primitive. Admin shares whichever suits the channel.
- Token is added to **Active invite tokens** list (§2.6); admin can come back to copy it again or revoke.
- TTL countdown updates live (TimelineView).
- Footer line reminds admin of workspace mode (so behavior is predictable).

### 2.3 Боб joins OPEN workspace (invitee path A)

Алина's workspace is `mode=open`. She posts link in #general Slack.

Боб clicks `leaf://invite/abc123...` in Slack:

```
┌─────────────────────────────────────────────┐
│  Join "TestRoom" team?                      │
│                                             │
│  Inviter: Алина                             │
│  Workspace mode: Open — instant join        │
│                                             │
│  YOUR DISPLAY NAME                          │
│  [ Bob Smith                             ]  │
│                                             │
│  [ Cancel ]              [ Join now ]       │
└─────────────────────────────────────────────┘
```

Боб clicks `[Join now]` → 2-3 second spinner → joined → success card → Боб's TeamView shows TestRoom.

**Alternative entry — code paste:**
Алина gives Боб the code `LEAF-A8X7-B3K9` (e.g. over phone). Боб opens Leaf → Sidebar bottom → `🔢 Join by code` → paste:

```
┌─────────────────────────────────────────────┐
│  Join workspace by code                     │
│                                             │
│  PASTE CODE                                 │
│  [ LEAF-A8X7-B3K9                        ]  │
│                                             │
│         [ Cancel ]    [ Continue ]          │
└─────────────────────────────────────────────┘
```

Then identical preview/join flow as link path.

**Алина offline:** doesn't matter. Боб joins immediately.

### 2.4 Боб joins CLOSED workspace (invitee path B)

Алина's workspace is `mode=closed`. Same link/code generation, same entry points (link click or code paste). Difference at preview:

```
┌─────────────────────────────────────────────┐
│  Request to join "TestRoom"?                │
│                                             │
│  Inviter: Алина                             │
│  Workspace mode: Closed — admin will        │
│  review your request                        │
│                                             │
│  YOUR DISPLAY NAME                          │
│  [ Bob Smith                             ]  │
│                                             │
│  [ Cancel ]            [ Send request ]     │
└─────────────────────────────────────────────┘
```

After `[Send request]`:

```
┌─────────────────────────────────────────────┐
│  Waiting for admin approval                 │
│                                             │
│  ⏳ Request sent to Алина.                  │
│  You'll get a notification when she         │
│  approves or declines.                      │
│                                             │
│  Request sent: just now                     │
│  Pending in queue                            │
│                                             │
│  [ Cancel request ]                         │
└─────────────────────────────────────────────┘
```

Боб can:
- Wait — sheet can be dismissed. Push notification will arrive on approve/decline.
- `[Cancel request]` — withdraws from admin queue, no admin notification.

**Алина offline at click moment:** doesn't matter. Request sits in queue server-side.

### 2.5 Алина reviews closed-mode queue (admin path C)

Алина opens Leaf next morning. She sees:

```
Sidebar (workspace switcher area):
  ✓ TestRoom  🔴 12 pending
    OtherTeam
```

Tapping the badge OR Settings → Workspace → Pending requests:

```
┌─────────────────────────────────────────────┐
│  Pending join requests · 12                 │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │ Bob Smith                           │    │
│  │ Requested 14h ago · via link        │    │
│  │ [ Decline ]         [ Approve ]    │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ Carol Mendez                        │    │
│  │ Requested 13h ago · via code        │    │
│  │ [ Decline ]         [ Approve ]    │    │
│  └─────────────────────────────────────┘    │
│  ...                                        │
│                                             │
│  [ Approve all (12) ]  [ Decline all ]      │
└─────────────────────────────────────────────┘
```

**Per-row info:**
- Display name (self-asserted by invitee)
- Timestamp of request
- Source: `via link` or `via code`
- Per-action buttons + bulk actions in header

Алина clicks `[Approve]` per row → invitee gets push `🟢 Алина approved you to TestRoom` → invitee app completes join in background.

Декline → silent (invitee gets a push `🔴 Your request to TestRoom was declined` — without further detail). Cancellable scope, see §7.

**No identity signal beyond display_name and timestamp.** This is a known limitation of pure-pubkey identity (see §9 — Out of scope). Алина uses her own judgment + the fact that requests came in via the link she posted in #general Slack to filter spam. Mass-decline available if a wave of obvious spam hits.

### 2.6 Алина manages active tokens (admin path D)

Settings → Workspace → Active invite tokens:

```
┌─────────────────────────────────────────────┐
│  Active invite tokens · 3                   │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │ Team kickoff                        │    │
│  │ Code: LEAF-A8X7-B3K9                │    │
│  │ Expires in 22h 14m · 0/∞ uses       │    │
│  │ [ Copy link ] [ Copy code ] [ ✕ ]  │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ Contractors                         │    │
│  │ Code: LEAF-F2Q3-X8M1                │    │
│  │ Expires in 6d 14h · 0/3 uses        │    │
│  │ [ Copy link ] [ Copy code ] [ ✕ ]  │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ Single-use for Dmitry               │    │
│  │ Code: LEAF-K9L4-P5R8                │    │
│  │ Expires in 23h 02m · 0/1 use        │    │
│  │ [ Copy link ] [ Copy code ] [ ✕ ]  │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  [ + Generate new ]    [ Revoke all ]       │
└─────────────────────────────────────────────┘
```

**Per-token:**
- Optional admin-provided label (e.g. "Team kickoff" / "Contractors") — set at generate time, can be left blank
- Code (short form)
- Status: TTL countdown + uses counter (0/∞ for unlimited, 0/N for capped)
- Per-token Copy + Revoke
- `[Revoke]` — mark token invalidated immediately. New click attempts get error «This invite was revoked».

Up to **10 active tokens** per workspace.

---

## 3. Data model

### 3.1 New `invite_tokens` table — Supabase + local mirror

| Column | Type | Notes |
|---|---|---|
| `token_id` | uuid PK | UUIDv4, used as URL token + base32 → code |
| `workspace_id` | uuid | FK workspaces |
| `created_by_pubkey` | text | hex pubkey of admin who generated |
| `label` | text | optional admin-set label («Team kickoff») |
| `mode_snapshot` | text | 'open' | 'closed' — captured at generation time (workspace mode may change later; existing tokens keep their snapshot) |
| `ttl_seconds` | int | TTL chosen at generate time |
| `expires_at` | timestamptz | created_at + ttl_seconds |
| `max_uses` | int NULL | NULL = unlimited; 1 = single-use |
| `used_count` | int default 0 | incremented atomically on use |
| `revoked_at` | timestamptz NULL | NULL = active; set on revoke |
| `encrypted_team_key` | bytea | wrapped team key blob (see §4) |
| `created_at` | timestamptz | |

**Indexes:**
- `(workspace_id) WHERE revoked_at IS NULL AND expires_at > now()` — admin active list query
- `(token_id)` — direct lookup at invitee click

**RLS:**
- `invite_tokens_admin_write` — workspace admin can INSERT / UPDATE (revoke) tokens for their workspace
- `invite_tokens_public_read_by_id` — anyone with valid `token_id` can SELECT (needed for invitee fetch) **BUT** only if `revoked_at IS NULL AND expires_at > now() AND (max_uses IS NULL OR used_count < max_uses)`. RLS expression encodes the validity check at fetch time.
- `invite_tokens_admin_list_read` — workspace admin can SELECT all tokens for their workspace (for Active tokens UI)

**Local mirror:** admin's Mac mirrors `invite_tokens` rows for their workspace (cache for instant UI). Mirror refreshed on workspace open + on admin generate/revoke action.

### 3.2 New `join_requests` table — Supabase only

| Column | Type | Notes |
|---|---|---|
| `request_id` | uuid PK | |
| `workspace_id` | uuid | FK |
| `token_id` | uuid | FK invite_tokens — which token they used |
| `invitee_pubkey` | text | hex |
| `invitee_display_name` | text | self-asserted |
| `status` | text | 'pending' | 'approved' | 'declined' | 'cancelled' | 'expired' |
| `created_at` | timestamptz | |
| `decided_at` | timestamptz NULL | when admin (or auto-open mode) decided |
| `decided_by_pubkey` | text NULL | admin pubkey on decide |

**Status transitions:**
- `pending` → `approved` (admin OR auto-approve in open mode)
- `pending` → `declined` (admin)
- `pending` → `cancelled` (invitee)
- `pending` → `expired` (token TTL hit while pending)

**RLS:**
- `join_requests_admin_read` — workspace admin reads all pending+decided for their workspace
- `join_requests_admin_update` — workspace admin sets status approved/declined
- `join_requests_self_read` — invitee reads their own request (by pubkey match)
- `join_requests_self_insert` — invitee creates row (with self-pubkey + valid token_id)
- `join_requests_self_cancel` — invitee sets own row status='cancelled' while pending

### 3.3 `workspaces` table additions

| Column | Type | Default | Notes |
|---|---|---|---|
| `mode` | text | 'closed' | enum 'open' | 'closed' |
| `default_invite_ttl_seconds` | int | 86400 | 24h default |
| `default_single_use` | int | 0 | bool, 0/1 |

### 3.4 `pending_invites` table — DEPRECATE

Existing S3 table `pending_invites` (single-row-per-invitee ECDH model) is kept for back-compat with v=1 envelopes already issued before this redesign ships. New invite generation writes only to `invite_tokens` + `join_requests`. After 30 days post-ship, drop `pending_invites` in cleanup migration.

### 3.5 Schema migration plan

**M027 — local (SQLCipher):**
- CREATE TABLE `invite_tokens`
- ALTER TABLE `workspaces` ADD COLUMN `mode`, `default_invite_ttl_seconds`, `default_single_use`
- Backfill existing `workspaces.mode = 'closed'` (safer default; admin can switch later)

**M027 — Supabase (parallel pgTAP suite):**
- CREATE TABLE `invite_tokens` + RLS policies + indexes
- CREATE TABLE `join_requests` + RLS policies + indexes
- ALTER TABLE `workspaces` ADD COLUMN `mode` + defaults
- Edge Functions: `create_join_request`, `approve_join_request`, `decline_join_request`, `cancel_join_request`, `revoke_invite_token`

---

## 4. Crypto envelope (engineering reference — NOT user-facing)

> *This section is for me + Дима reviewing the design. Anton said «забудь крипту» — he doesn't need to read this. The product behavior in §2 is what matters for him.*

### 4.1 Envelope version

`version = 2` byte for invite blobs. `version = 1` (current S3 ECDH-to-invitee) stays valid for accept-side compatibility until 30-day deprecation window passes.

### 4.2 Open mode — token-derived wrap

At admin generation:

```
token_bytes = secure_random(32)
wrap_key = HKDF-SHA256(
    ikm=token_bytes,
    salt=workspace_id_bytes,
    info="leaf-invite-v2-open",
    L=32
)
ct = AES-GCM-Seal(key=wrap_key, nonce=random(12), aad=header, plaintext=teamKey)
blob = [version:1 | nonce:12 | ct:N | tag:16]
```

Blob stored in `invite_tokens.encrypted_team_key`. Admin's local copy of `wrap_key` is discarded — only `token_bytes` (rendered to user as link + code) is retained.

At invitee click (open mode flow):

```
1. token_bytes ← decode(link or code)
2. invitee app POSTs join_requests row { token_id, invitee_pubkey, display_name }
   → Edge Function `create_join_request` auto-approves in open mode
   → atomic UPDATE invite_tokens.used_count + status='approved'
3. invitee app fetches invite_tokens row (RLS now permits — request status='approved')
4. wrap_key ← HKDF-SHA256(...same as above...)
5. teamKey ← AES-GCM-Open(wrap_key, blob.nonce, blob.ct, blob.tag)
6. INSERT INTO team_members ... INSERT INTO team_keys ...
```

The `join_requests` row is still created in open mode — for audit + new_member_joined notification + used_count enforcement. The only difference vs closed mode is auto-approval bypassing admin gate.

**Threat model:**
- Anyone with `token_bytes` (i.e. anyone with link or code) can derive `wrap_key` and decrypt `teamKey`. **Token = teamKey access.**
- Token leak = team-read compromise until revoke. After revoke, blob row is `revoked_at IS NOT NULL` so RLS hides it; even attackers with token can't refetch. But if they ALREADY fetched + decrypted, they have teamKey snapshot.
- Mitigation: admin can rotate team key via existing M009 `rotation_outbox` substrate. Past-fetched teamKey becomes useless for FUTURE data.
- This is the explicit trade-off the admin accepts by choosing **open mode**.

### 4.3 Closed mode — same wrap, server-gated release

At admin generation: identical to open mode.

At invitee click:

```
1. invitee app POSTs join_requests row { token_id, invitee_pubkey, display_name }
   → status='pending'
2. Edge Function validates token validity (RLS check) → 201 OK or 4xx
3. Invitee app shows "waiting for admin" UI
4. Push to admin: join_request_received (kind=invite_request)
```

At admin approve:

```
1. Admin clicks Approve → app PATCHes join_requests row → status='approved'
2. Edge Function on UPDATE: 
   - increment invite_tokens.used_count
   - if used_count reaches max_uses: mark token used-up (still readable by accepted requests, not by future click)
   - notify invitee via APNs (kind=invite_approved)
3. Invitee app on push: fetches invite_tokens row → derives wrap_key → decrypts teamKey → joins
```

**Crucial:** the encrypted_team_key blob is **the same blob** as open mode — derived from token_bytes only, not from invitee pubkey. The «approval» is purely an application-layer gate: server's RLS permits invitee to FETCH the blob ONLY if their request status='approved'. After approval, decryption is identical to open mode.

**Why this works:**
- Admin doesn't need to be online at invitee click — request sits in queue
- Admin doesn't need to be online at approve time either — they approve when convenient, server pushes invitee
- Crypto envelope is the same for both modes — only the access-gate differs

**Threat model for closed:**
- If RLS is bypassed (Supabase compromise / SQL injection), blob is fetchable by anyone with token → same as open mode security
- Defence-in-depth: keep RLS tight; rotate team key on suspected leak
- Token leak alone (no Supabase compromise) ≠ access; attacker hits `403 forbidden` from RLS when fetching blob without approved request

### 4.4 Team key rotation triggers (no change to substrate)

Reuse existing M009 `rotation_outbox` flow:
- Admin manually rotates from Settings → Workspace → Security → `Rotate team key`
- Recommend rotation after any token revoke for high-sensitivity workspaces (UI hint, not auto)
- Auto-rotate on member removal (existing S3 behavior, unchanged)

### 4.5 Single-use semantics

`max_uses=1` enforced via atomic UPDATE in `approve_join_request` Edge Function (closed mode) or `auto_approve_open_join` Edge Function (open mode):

```sql
UPDATE invite_tokens
SET used_count = used_count + 1
WHERE token_id = $1
  AND (max_uses IS NULL OR used_count < max_uses)
  AND revoked_at IS NULL
  AND expires_at > now()
RETURNING *;
-- If 0 rows: token consumed, reject with 409 Conflict
```

Race condition between 2 simultaneous approvals on a single-use token: atomic UPDATE serializes; second loser gets 409.

### 4.6 Replay / token harvesting

`token_id` = UUIDv4 (122 bits entropy). Brute-force unrealistic. Token URL has no checksum — code form `LEAF-XXXX-XXXX` includes 1-byte checksum for typo detection at paste time (mirrors current `JoinCode.encode`).

---

## 5. UI components — new + modified

### 5.1 New

| Component | Location | Purpose |
|---|---|---|
| `WorkspaceCreateSheet` (rewrite) | `Leaf/Views/Window/Settings/` | Add mode picker + TTL preset + single-use default |
| `GenerateInviteSheet` (rewrite) | `Leaf/Views/Window/Team/` | TTL override + label input + dual link/code output |
| `ActiveTokensSection` | `Leaf/Views/Window/Settings/Workspace/` | List + copy + revoke per token |
| `PendingRequestsSection` | `Leaf/Views/Window/Settings/Workspace/` | List + approve/decline + bulk actions |
| `JoinWorkspaceByCodeSheet` | `Leaf/Views/Window/Settings/` | Invitee paste-code entry |
| `JoinRequestWaitingCard` | `Leaf/Views/Window/Settings/` | Sub-view of `AcceptInviteSheet` for closed-mode wait state |
| `InviteTokensReader` | `Leaf/Models/` | @Observable wrapper around InviteTokenStore |
| `JoinRequestsReader` | `Leaf/Models/` | @Observable admin-side queue |
| `WorkspaceModeService` | `Packages/LeafCore/Sources/LeafCore/Team/` | Open/closed mode + default-TTL setters |
| `InviteTokenService` | `Packages/LeafCore/Sources/LeafCore/Team/` | Generate / list / revoke tokens |
| `JoinRequestService` | `Packages/LeafCore/Sources/LeafCore/Team/` | Submit / cancel / list / approve / decline requests |

### 5.2 Modified

| Component | Change |
|---|---|
| `Sidebar` | Add `🔢 Join by code` row near `Join workspace` (or replace) + pending-requests badge per workspace |
| `AcceptInviteSheet` | Dispatch by envelope version: v=1 → existing flow, v=2 open → instant, v=2 closed → waiting card |
| `LeafWorkspaceSwitcher` | Per-row red badge for pending request count (admin view only) |
| `WindowSettingsView` | New `WorkspaceSettingsSection` sub-sections: Workspace mode + default TTL row (via `WorkspaceModeService`) + Active tokens + Pending requests |
| `InviteURLHandler` | Detect v=2 token format; route to new accept path |

### 5.3 Removed

- `GenerateInviteSheet` «Paste Join code» tab (current — bilateral pubkey exchange UX) — replaced by token generation flow.
- `JoinTeamStepView` (onboarding step) — pivots to a simplified «Have an invite link or code? Paste it» entry; Join code itself is no longer a primary user-facing primitive (deprecate `JoinCode.encode` for new flows; keep for v=1 back-compat).

---

## 6. Notifications

Extend `notification_prefs` per-device row (Track 5 / S8 / M026) with new event types:

| Event | Default ON/OFF | Recipient | Trigger |
|---|---|---|---|
| `invite_request_received` | ON | admin | Closed-mode invitee POSTs join_requests row |
| `invite_request_approved` | ON | invitee | Admin approves request |
| `invite_request_declined` | ON | invitee | Admin declines request |
| `invite_token_expired` | OFF | admin | Token TTL hit (informational; admin may want quiet) |
| `new_member_joined` | OFF | admin | Anyone joined via any token (informational, esp. for open mode) |

APNs categories:
- `leaf.invite.request` (admin-side) — actions `[Approve] [Decline]` (deep-link to PendingRequestsSection on tap)
- `leaf.invite.decision` (invitee-side) — no actions, tap deep-links to workspace if approved

**In-app:**
- Sidebar workspace badge: red dot + count for admin's pending-requests-where-I-am-admin
- Banner in TeamView header: "12 pending requests — Review" when count > 0

---

## 7. Default behaviors / settings

| Knob | Default | Override |
|---|---|---|
| Workspace mode at creation | `closed` | mode picker in `WorkspaceCreateSheet` |
| Default invite TTL | 24 hours | TTL picker in `WorkspaceCreateSheet` |
| Default single-use | `false` (unlimited) | Toggle in `WorkspaceCreateSheet` |
| TTL options | 1h / 24h / 7d / 30d / Never expires | Hardcoded enum; «Never» = NULL `expires_at` |
| Max active tokens per workspace | 10 | Hardcoded; error on 11th generate attempt |
| Token code format | `LEAF-XXXX-XXXX` (10 base32 chars, no I/L/O/U/0/1) | Single primitive, `JoinCode.encode` deprecated |
| Token label | empty | Optional text input at generate time |
| Invitee display name default | `NSFullUserName()` | Editable in preview card |
| Invitee can cancel pending | yes | `[Cancel request]` button in waiting card |
| Cancellation notifies admin | NO | Silent; admin queue just drops the row |
| Bulk approve | yes | `[Approve all]` button (closed mode only, when ≥2 pending) |
| Bulk decline | yes | `[Decline all]` button (with confirmation modal) |
| Decline notifies invitee | YES (informational push, no reason) | non-toggleable in MVP |
| Mode change post-creation | allowed via Settings | Tokens generated under old mode retain `mode_snapshot` of generation time |

---

## 8. Tier-gate interaction (existing T3-T4 substrate)

| Action | Free | Team |
|---|---|---|
| Create workspace | ❌ Upgrade modal | ✅ |
| Generate invite token | ❌ (because workspace creation gated) | ✅ |
| Accept invite (be added as member) | ✅ | ✅ |
| Approve pending request as admin | ❌ Upgrade modal (since only Team can be admin) | ✅ |

Tier gating is enforced at action-handler level per existing `TierGate.canCreateWorkspace` / `canAcceptInvite` checks. New `TierGate.canApproveJoinRequest` mirrors `canCreateWorkspace` (same gate).

---

## 9. Out of scope (Track 6 / post-launch)

Documented for future reference. Each is a deliberate non-decision in this spec.

### 9.1 Identity anchors beyond pubkey
- **Email-domain allowlist** (e.g. `@acme.com`) — admin filter by domain in closed mode queue
- **Pre-allowlist by email list** — admin paste 50 emails; only those can request
- **Vouching by existing member** — invitee picks vouching member; member confirms → request enters queue with «vouched by X» tag

These would close the «admin can't tell legit from spam in 50-person blind queue» gap. They require email/identity layer atop pubkey — a **whitepaper-level decision** that this redesign deliberately does not take. The current spec ships pure pubkey identity + admin manual filter as MVP; Track 6 evaluates if Leaf product positioning admits email layer.

### 9.2 Bulk discovery
- **Username/handle directory** — search-by-handle in TOFU registry
- **QR / NFC pairing** — in-person bulk add

### 9.3 Spam protection
- **Rate-limit per token** — N requests/hour cap
- **Captcha** on join request submission

### 9.4 Advanced lifecycle
- **Token rotation** — auto-rotate active tokens daily for paranoid mode
- **Geo/IP restrictions** — admin allowlists country/ASN
- **Multi-admin approval** — N-of-M required for high-security workspaces

### 9.5 Migration tooling
- Bulk-import existing v=1 `pending_invites` rows to v=2 — N/A; deprecation window handles this passively.

---

## 10. Acceptance gates (manual smoke)

Two-Mac signed-build session. Mac A = Алина (admin), Mac B = Боб (invitee).

| # | Scenario | Expected |
|---|---|---|
| **G1** | Open workspace, link click | Boб clicks link in Slack → Leaf opens → preview → display name → `[Join now]` → ≤3s joined |
| **G2** | Open workspace, code paste | Same end-state via Sidebar `Join by code` → paste `LEAF-XXXX-YYYY` → joined |
| **G3** | Closed workspace, link click + approve | Боб clicks → request submitted → Алина gets push → approve → Боб gets push → joined |
| **G4** | Closed workspace, decline | Same as G3 but Алина declines → Боб gets push «declined» |
| **G5** | TTL expiry | Token with TTL=1m → wait 70s → click → Боб sees «This invite has expired» |
| **G6** | Revoke before TTL | Алина revokes → Боб clicks → Боб sees «This invite was revoked» |
| **G7** | Multiple active tokens | Алина generates 3 tokens (Team kickoff / Contractors / Single-Dmitry) → revoke one → other two still work |
| **G8** | Single-use token | Token `max_uses=1` → Боб joins → Carol clicks → Carol sees «This invite is no longer accepting joiners» |
| **G9** | Cancel pending request | Closed mode → Боб submits → Боб clicks `[Cancel request]` → Алина's queue no longer shows Боб |
| **G10** | Admin offline at both clicks | Алина closes Mac → Боб clicks (closed mode) → request enters queue → Алина opens Mac next day → queue shows request → approve → Боб app fetches + joins |
| **G11** | Admin offline + open mode | Алина closes Mac → Боб clicks (open mode) → joined immediately, Алина's Mac state irrelevant |
| **G12** | Bulk approve | 5 pending requests → Алина clicks `[Approve all]` → confirm modal → all 5 get push + joined |
| **G13** | Workspace mode switch | Алина flips mode closed→open in Settings → existing pending requests stay in queue (mode_snapshot on token preserves behavior) → new tokens reflect new mode |
| **G14** | Link leak in closed mode | Алина shares link in Slack #general → 50 click → queue shows 50 → Алина mass-declines spammers, approves teammates |
| **G15** | Link leak in open mode → revoke + rotate | Алина revokes → generates new token → manually rotates team key → past leakers lose future-data decrypt ability |

---

## 11. Implementation phase breakdown

Suggest 8-10 atomic commits in this order (each ends with build green + tests). Plan-level detail comes in subsequent writing-plans-skill phase, not this spec.

1. **Schema M027 — local + Supabase** with stubs (pgTAP for RLS, no Edge Functions yet)
2. **InviteToken value type + InviteTokenStore (local SQLCipher) + tests**
3. **InviteTokenService.generate / list / revoke + envelope v=2 codec** (in LeafCorePrivate moat)
4. **Edge Functions: `create_join_request` / `cancel_join_request` (invitee side) + tests**
5. **Edge Functions: `approve_join_request` / `decline_join_request` / `revoke_invite_token` (admin side) + tests**
6. **WorkspaceCreateSheet rewrite (mode picker + TTL preset)**
7. **GenerateInviteSheet rewrite (dual link/code output + label + TTL override)**
8. **ActiveTokensSection + PendingRequestsSection in Settings → Workspace**
9. **JoinWorkspaceByCodeSheet + Sidebar wiring + AcceptInviteSheet v=2 dispatch + waiting state**
10. **Notification integration (APNs categories + `notification_prefs` events) + manual smoke checklist**

Build green at each commit. Full xcodebuild 5-scheme regression at each commit. SPM test suite must stay green; new tests land alongside their corresponding feature commit.

---

## 12. Migration / coexistence with v=1 envelope

- **Generation side:** new code path writes ONLY v=2 to `invite_tokens`. v=1 generation (`InviteService.generateInvite(workspaceID:inviteePubkeyHex:requireOTP:)`) marked `@available(*, deprecated)` and removed from public UI; kept in LeafCore for back-compat acceptance only.
- **Acceptance side:** `AcceptInviteSheet` envelope detection:
  - URL token format `leaf://invite/<22-base64url>?w=<name>&a=<64-hex>` → v=1 path (existing S3 flow)
  - URL token format `leaf://invite/<22-base64url>` (no `a=` admin pubkey query param) → v=2 path
  - Code format `LEAF-XXXX-XXXX` → v=2 path only (no v=1 code format existed)
- **Sunset:** 30 days post-ship, v=1 generation code path deleted entirely. v=1 acceptance kept for users who still have pending v=1 links; after another 30 days delete v=1 acceptance code too (`pending_invites` table dropped in same migration).

---

## 13. Open questions for Дима review

1. **Open mode team-read leak threat** — explicitly accept this as product trade-off, or block open mode at MVP and ship closed-only first?
2. **Email anchor (§9.1)** — wholly out of scope per whitepaper «pubkey-anchored, no PII» positioning, or revisit if 50+ team feedback after MVP demands it?
3. **`new_member_joined` admin push default OFF** — should it default ON for closed mode (since admin chose to gate, they probably want confirmation of result) and OFF for open mode (where joins are expected)?
4. **Per-token labels** — should label be mandatory or truly optional? Mandatory adds friction; optional risks unlabeled token soup.
5. **Bulk decline modal copy** — «Decline all 12 requests? They will be notified.» — is this user-visible cost acceptable, or should mass-decline be silent (no push to declinees)?

---

## 14. Self-review checklist

- ✅ No placeholders / TBD (all sections written)
- ✅ Schema and RLS policies named explicitly
- ✅ UX walkthrough covers all 6 paths (admin create / admin generate / admin approve / admin manage / invitee open / invitee closed)
- ✅ Crypto section is self-contained engineering reference, marked as such
- ✅ Migration plan + deprecation window stated
- ✅ Out-of-scope explicit (§9)
- ✅ 15 acceptance gates concrete + measurable
- ✅ Implementation phases atomic (each commit builds green)
- ✅ Tier-gate integration unambiguous (§8 table)
- ✅ Notification + APNs categories enumerated
- ✅ Default settings table complete (§7)
