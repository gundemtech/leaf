# Invite System Redesign — Closed Workspaces (MVP)

**Status:** Draft v3 (2026-05-20). Brainstorm + 5 open questions resolved + 3 follow-up amendments per Anton's review (unified token=code primitive, simplified tier-gate table, explicit Delete action). **Closed-mode-only MVP.** Open mode deferred to post-launch (see §9.1).
**Owner:** Local Claude (Mac).
**Branch:** TBD — implementation not yet scheduled. Spec lands first, plan + execution follow as separate phase.
**Predecessor:** Track 5 / S3 magic-link invite (current per-invitee ECDH model with mandatory bilateral Join code exchange).
**Cross-reference:**
- `fix/in-app-join-workspace-entry` — interim UX-gap fixes (in-app Join entry in Sidebar + Join code visible in Settings → Account). Superseded by this redesign but stays as bridge until shipped.
- Track 5 / S3 spec — `docs/superpowers/specs/2026-05-15-track-5-S3-magic-link-invite.md` (envelope v=1 ECDH-to-invitee — **reused as-is** in this redesign).
- Track 5 S8 spec — `docs/superpowers/specs/2026-05-19-track-5-S8-polish-settings.md` (Tier-gate substrate, notification_prefs, MVP default `tier="team"`).

---

## 1. Goal — fitness function

Workspace invite flow is **done** when:

1. **Admin sees ONE generate-invite action per workspace,** produces a token rendered as both a clickable link AND a typeable short code. Admin chooses TTL.
2. **All workspaces are closed by default and by sole option in MVP.** Anyone with link/code becomes a pending request that admin approves or declines.
3. **30-50 person team kickoff** = one link in Slack #general + admin reviews queue. **NOT** 30 bilateral Join-code round-trips.
4. **Admin's Mac online state at invitee click moment is irrelevant.** Closed-mode requests queue server-side. Admin reviews queue when convenient.
5. **Link leak** drowns admin in pending requests from outsiders BUT grants no access — admin filters via approve UI. Admin can delete compromised token + generate new one.
6. **TTL expiry** auto-invalidates tokens without admin action.
7. **Multiple active tokens** coexist on one workspace (admin can have separate tokens for team + contractors + vendors with different TTLs).
8. **Delete** any token at any time, including before TTL (soft-delete; row stays in DB for audit).
9. **Crypto envelope unchanged** — reuses Track 5 / S3 v=1 ECDH-to-invitee at approval moment. No whitepaper-level decisions.
10. **Manual smoke** (11 gates, §10 below) passes on signed two-Mac build.

---

## 2. UX walkthrough

Concrete scenarios with screen-level detail. No crypto words.

### 2.1 Алина creates workspace (admin path A)

Алина opens Leaf, clicks `+ Add workspace` in Sidebar bottom.

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
│  All new workspaces require admin approval  │
│  for each new member.                       │
│                                             │
│         [ Cancel ]    [ Create ]            │
└─────────────────────────────────────────────┘
```

**Notes:**
- No mode picker — closed-mode is sole option in MVP.
- TTL + single-use are defaults for new tokens; per-token override available.
- Footer copy makes the closed-mode behavior explicit so admin knows what to expect.
- Defaults editable later in Settings → Workspace.

### 2.2 Алина generates invite (admin path B)

In TeamView (or Settings → Workspace → Active invite tokens), Алина clicks `+ Generate invite`.

**`GenerateInviteSheet` rewrite:**

```
┌─────────────────────────────────────────────┐
│  Generate invite                            │
│                                             │
│  LABEL (optional)                           │
│  [ Team kickoff                          ]  │
│  Use to distinguish multiple active tokens. │
│                                             │
│  TTL                                        │
│  [ 24 hours          ▼ ]                    │
│                                             │
│  ◯ Single-use (token expires after 1 use)  │
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
│  │ leaf://invite/LEAF-A8X7-B3K9-Q2N4       │    │
│  └─────────────────────────────────────┘    │
│  [ Copy link ]                              │
│                                             │
│  🔢 CODE (read over phone / paste in-app)   │
│  ┌─────────────────────────────────────┐    │
│  │   LEAF-A8X7-B3K9-Q2N4                    │    │
│  └─────────────────────────────────────┘    │
│  [ Copy code ]                              │
│                                             │
│  ⏰ Expires in 23h 59m                       │
│  🔄 0 / unlimited uses                       │
│  🔒 Anyone using this needs your approval   │
│                                             │
│            [ Done ]                         │
└─────────────────────────────────────────────┘
```

**Notes:**
- ONE token, TWO renderings (link + code) — same primitive. Admin shares whichever suits the channel.
- Token is added to **Active invite tokens** list (§2.5); admin can come back to copy it again or delete.
- TTL countdown updates live (TimelineView).
- Footer line reminds admin that approval is required — predictable behavior.
- Label is optional. Empty label → token shown as «Untitled token #1234» in Active tokens list.

### 2.3 Боб joins (invitee path)

Алина shares link `leaf://invite/LEAF-A8X7-B3K9-Q2N4` (in Slack) or code `LEAF-A8X7-B3K9-Q2N4` (over phone) with Боб. Link path = code; one primitive, two input methods.

**Path A — link click in Slack:**

Боб clicks → Leaf activates → preview card:

```
┌─────────────────────────────────────────────┐
│  Request to join "TestRoom"?                │
│                                             │
│  Inviter: Алина                             │
│  Admin will review your request before      │
│  you can join.                              │
│                                             │
│  YOUR DISPLAY NAME                          │
│  [ Bob Smith                             ]  │
│                                             │
│  [ Cancel ]            [ Send request ]     │
└─────────────────────────────────────────────┘
```

**Path B — code paste:**

Боб opens Leaf → Sidebar bottom → `🔢 Join by code` → paste:

```
┌─────────────────────────────────────────────┐
│  Join workspace by code                     │
│                                             │
│  PASTE CODE                                 │
│  [ LEAF-A8X7-B3K9-Q2N4                        ]  │
│                                             │
│         [ Cancel ]    [ Continue ]          │
└─────────────────────────────────────────────┘
```

Then identical preview/request flow as Path A.

**After `[Send request]`:**

```
┌─────────────────────────────────────────────┐
│  Waiting for admin approval                 │
│                                             │
│  ⏳ Request sent to Алина.                  │
│  You'll get a notification when she         │
│  approves your request.                     │
│                                             │
│  Request sent: just now                     │
│  Pending in queue                            │
│                                             │
│  [ Cancel request ]                         │
└─────────────────────────────────────────────┘
```

Боб can:
- Wait — sheet can be dismissed. Push notification will arrive on approve.
- `[Cancel request]` — withdraws from admin queue silently. No admin notification.

**Алина offline at click moment:** doesn't matter. Request sits in queue server-side until she next opens Leaf.

### 2.4 Алина reviews queue (admin path C)

Алина opens Leaf next morning. Sidebar shows:

```
LEAF
  Home
  Activity
COLLABORATION
  Team
  Connections
ACCOUNT
  Settings
  Profile

(workspace switcher at bottom)
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

**Approve action:**
- Алина taps `[Approve]` → her Mac immediately seals teamKey for Bob's pubkey (locally, ECDH from S3 envelope) → uploads to `join_requests.encrypted_team_key` → request status flips to `approved`
- Bob receives APNs push «Алина approved your request» → Bob's app fetches blob + decrypts + joins
- Bob shows up in TestRoom member list within ~5 seconds

**Decline action:**
- Алина taps `[Decline]` → request status flips to `declined`
- **No push** sent to Bob (per Anton's decision §13.5: «если отклонили то нет пуша»)
- Bob's waiting card silently updates to «Request declined» state on next state poll (~30s) or via Realtime if subscribed. No system notification.

**Bulk actions:**
- `[Approve all (N)]` — confirmation modal «Approve all 12 requests? Each will receive a notification.» → approves all → each invitee gets push
- `[Decline all]` — confirmation modal «Decline all 12 requests? They will not be notified.» → declines all silently

**No identity signal beyond display_name and timestamp.** This is a known limitation of pure-pubkey identity (see §9 — Out of scope). Алина uses her own judgment + the fact that requests came in via the link she posted in #general Slack to filter spam. Mass-decline available if a wave of obvious spam hits.

### 2.5 Алина manages active tokens (admin path D)

Settings → Workspace → Active invite tokens:

```
┌─────────────────────────────────────────────┐
│  Active invite tokens · 3                   │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │ Team kickoff                        │    │
│  │ Code: LEAF-A8X7-B3K9-Q2N4                │    │
│  │ Expires in 22h 14m · 0/∞ uses       │    │
│  │ [ Copy link ] [ Copy code ] [ ✕ ]  │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ Contractors                         │    │
│  │ Code: LEAF-F2Q3-X8M1-J7P5                │    │
│  │ Expires in 6d 14h · 0/3 uses        │    │
│  │ [ Copy link ] [ Copy code ] [ ✕ ]  │    │
│  └─────────────────────────────────────┘    │
│  ┌─────────────────────────────────────┐    │
│  │ Untitled token #4F2                 │    │
│  │ Code: LEAF-K9L4-P5R8-T3M9                │    │
│  │ Expires in 23h 02m · 0/1 use        │    │
│  │ [ Copy link ] [ Copy code ] [ ✕ ]  │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  [ + Generate new ]    [ Delete all ]       │
└─────────────────────────────────────────────┘
```

**Per-token:**
- Optional admin-provided label (e.g. «Team kickoff»). Empty → «Untitled token #<short hash>» auto-display.
- Code (short form)
- Status: TTL countdown + uses counter (0/∞ for unlimited, 0/N for capped)
- Per-token Copy + Delete
- `[✕] Delete` — confirms via small modal «Delete this invite? Anyone trying to use it will see «This invite no longer exists».» Soft-delete (row stays in DB for audit; just disappears from Active tokens UI).

Up to **10 active tokens** per workspace.

---

## 3. Data model

### 3.1 New `invite_tokens` table — Supabase + local mirror

| Column | Type | Notes |
|---|---|---|
| `code` | text PK | base32 short code with checksum, e.g. `LEAF-A8X7-B3K9-Q2N4` (12 random chars + 4 checksum = 16 visible chars, ~70 bits entropy). Same string is BOTH the code (typed in-app) AND the URL path component (`leaf://invite/<code>`). |
| `workspace_id` | uuid | FK workspaces |
| `created_by_pubkey` | text | hex pubkey of admin who generated |
| `label` | text NULL | optional admin-set label |
| `ttl_seconds` | int | TTL chosen at generate time |
| `expires_at` | timestamptz | created_at + ttl_seconds (NULL if «Never expires») |
| `max_uses` | int NULL | NULL = unlimited; 1 = single-use |
| `used_count` | int default 0 | incremented atomically on approval |
| `deleted_at` | timestamptz NULL | NULL = active; set on delete (soft-delete; row stays for audit) |
| `created_at` | timestamptz | |

**No crypto material on this table.** Token is a pure identifier; the teamKey blob is sealed at approve moment and stored on `join_requests` (§3.2).

**Indexes:**
- `(workspace_id) WHERE deleted_at IS NULL AND (expires_at IS NULL OR expires_at > now())` — admin active list query
- `(code)` — direct lookup at invitee click

**RLS:**
- `invite_tokens_admin_write` — workspace admin can INSERT / UPDATE (delete) tokens for their workspace
- `invite_tokens_admin_list_read` — workspace admin can SELECT all tokens for their workspace (Active tokens UI)
- `invite_tokens_public_read_by_id` — anyone with valid `code` can SELECT a single row for preview purposes (workspace name, admin name, mode indicator) IF token is still valid `(deleted_at IS NULL AND (expires_at IS NULL OR expires_at > now()) AND (max_uses IS NULL OR used_count < max_uses))`

**Local mirror:** admin's Mac mirrors `invite_tokens` rows for their workspace (cache for instant UI). Mirror refreshed on workspace open + on admin generate/delete action.

### 3.2 New `join_requests` table — Supabase

| Column | Type | Notes |
|---|---|---|
| `request_id` | uuid PK | |
| `workspace_id` | uuid | FK |
| `code` | text | FK invite_tokens.code — which token they used |
| `invitee_pubkey` | text | hex |
| `invitee_display_name` | text | self-asserted |
| `status` | text | `pending` / `approved` / `declined` / `cancelled` / `expired` |
| `encrypted_team_key` | bytea NULL | sealed by admin's device at approve moment (S3 envelope v=1); NULL while `status != approved` |
| `created_at` | timestamptz | |
| `decided_at` | timestamptz NULL | when admin decided |
| `decided_by_pubkey` | text NULL | admin pubkey on decide |

**Status transitions:**
- `pending` → `approved` (admin)
- `pending` → `declined` (admin)
- `pending` → `cancelled` (invitee)
- `pending` → `expired` (token TTL hit while pending — daily cron sweep)

**RLS:**
- `join_requests_admin_read` — workspace admin reads all pending+decided for their workspace
- `join_requests_admin_update_approve` — workspace admin can set status='approved' AND populate `encrypted_team_key`
- `join_requests_admin_update_decline` — workspace admin can set status='declined'
- `join_requests_self_read` — invitee reads their own request (by pubkey match) — sees status + encrypted_team_key on approve
- `join_requests_self_insert` — invitee creates row (with self-pubkey + valid code; Edge Function validates token before INSERT)
- `join_requests_self_cancel` — invitee sets own row status='cancelled' while pending

### 3.3 `workspaces` table additions

| Column | Type | Default | Notes |
|---|---|---|---|
| `default_invite_ttl_seconds` | int | 86400 | 24h default for new tokens |
| `default_single_use` | int | 0 | bool, 0/1 |

**No `mode` column** — closed-mode is sole behavior in MVP. Open mode + `mode` column may land in post-launch (see §9.1).

### 3.4 `pending_invites` table — DEPRECATE

Existing S3 table `pending_invites` (single-row-per-invitee ECDH model) stays for back-compat with v=1 links already issued before this redesign ships. New invite generation writes only to `invite_tokens` + `join_requests`. After 30-day deprecation window post-ship, drop `pending_invites` in cleanup migration.

### 3.5 Schema migration plan

**M027 — local (SQLCipher):**
- CREATE TABLE `invite_tokens`
- ALTER TABLE `workspaces` ADD COLUMN `default_invite_ttl_seconds`, `default_single_use`
- Backfill defaults from constants

**M027 — Supabase (parallel pgTAP suite):**
- CREATE TABLE `invite_tokens` + RLS policies + indexes
- CREATE TABLE `join_requests` + RLS policies + indexes
- ALTER TABLE `workspaces` ADD COLUMN defaults
- Edge Functions: `create_join_request`, `approve_join_request`, `decline_join_request`, `cancel_join_request`, `delete_invite_token`, `expire_stale_join_requests` (daily cron)

---

## 4. Crypto envelope (engineering reference — NOT user-facing)

> *Anton said «забудь крипту» — this section is for me + Дима during plan-writing. Anton can skip.*

### 4.1 Envelope version — unchanged

**Reuses S3 envelope v=1** (`ECDH-to-invitee`). No new envelope version. No whitepaper-level decision. The redesign is purely about **timing and storage location** of the existing crypto operation:

| Where | S3 (current) | This redesign |
|---|---|---|
| Admin generates invite for SPECIFIC invitee pubkey | Yes — admin must have invitee pubkey upfront via off-band Join code exchange | No — admin generates a token primitive with no crypto material |
| When does admin seal teamKey for invitee | At generation time | At approval time (when admin clicks Approve and the request has the invitee's pubkey attached) |
| Where does sealed blob live | `pending_invites.encrypted_team_key` (Supabase, S3 schema) | `join_requests.encrypted_team_key` (Supabase, new schema) |
| Admin online dependency at invitee click | Yes (must seal during off-band exchange) | No (invitee can click any time; request queues) |
| Admin online dependency at approve | Yes (admin's device does the ECDH) | Yes — but admin is online when clicking Approve (trivially) |

**Same crypto operation, decoupled from off-band Join code exchange.**

### 4.2 Approval flow (full sequence)

```
1. Admin opens Leaf → Sidebar shows pending count badge
2. Admin navigates to Settings → Workspace → Pending requests
3. Local app fetches join_requests WHERE workspace_id = X AND status = 'pending'
4. UI renders list

5. Admin taps [Approve] on Bob's request
6. Local app:
   - reads bob_pubkey from join_requests row
   - reads admin_priv from local keystore
   - reads active teamKey from local keystore
   - ECDH(admin_priv, bob_pubkey) → shared_secret
   - HKDF(shared_secret, salt=workspace_id, info="leaf-invite-v1") → wrap_key  ← same as S3
   - AES-GCM-Seal(wrap_key, teamKey) → blob
7. Local app PATCHes join_requests SET status='approved', encrypted_team_key=blob, decided_at=now()
8. Edge Function `approve_join_request` fires:
   - validates admin claim (JWT pubkey matches workspace admin)
   - atomically: increment invite_tokens.used_count; check max_uses if set
   - if max_uses exhausted: mark token as «no longer accepting» (does NOT auto-delete; admin's call)
   - sends APNs push to bob (kind=invite_request_approved)
9. Bob's app on push:
   - fetches own join_requests row (RLS allows self-read)
   - reads encrypted_team_key
   - ECDH(bob_priv, admin_pubkey from row's decided_by_pubkey) → shared_secret
   - HKDF(...) → wrap_key
   - AES-GCM-Open(blob) → teamKey
   - INSERT INTO team_members ... INSERT INTO team_keys ...
   - UI flips to «Joined» success card
```

### 4.3 Decline flow

```
1. Admin taps [Decline] on Bob's request
2. Local app PATCHes join_requests SET status='declined', decided_at=now()
3. Edge Function `decline_join_request` fires:
   - validates admin claim
   - DOES NOT touch invite_tokens.used_count (declined ≠ used)
   - DOES NOT send push (per Anton's §13.5 decision)
4. Bob's app picks up status change via:
   - Supabase Realtime subscription (if app is open) — instant flip to «Declined» UI
   - OR scenePhase poll on next foreground (~30s loop) — eventual flip
5. UI shows «Request declined» state in JoinRequestWaitingCard; no system notification fires
```

### 4.4 Cancel flow (invitee initiates)

```
1. Bob taps [Cancel request] in waiting card
2. Local app PATCHes join_requests SET status='cancelled'
3. Edge Function `cancel_join_request` validates:
   - invitee_pubkey == JWT pubkey claim
   - status was 'pending'
4. Admin's queue refreshes on next foreground / Realtime — Bob's row disappears
5. No push to admin (silent withdrawal)
```

### 4.5 Token delete flow

```
1. Admin taps [✕ Delete] on token in Active tokens list, confirms modal
2. Local app PATCHes invite_tokens SET deleted_at=now()
3. Edge Function `delete_invite_token` validates admin claim
4. Pending join_requests against this token: NOT auto-cancelled (admin reviews them as usual; new clicks against this token fail at create_join_request validation step)
5. Future link clicks: Edge Function `create_join_request` checks token validity → returns 410 Gone → invitee sees «This invite no longer exists»
```

### 4.6 Single-use semantics

`max_uses=1` enforced via atomic UPDATE in `approve_join_request`:

```sql
UPDATE invite_tokens
SET used_count = used_count + 1
WHERE code = $1
  AND (max_uses IS NULL OR used_count < max_uses)
  AND deleted_at IS NULL
  AND (expires_at IS NULL OR expires_at > now())
RETURNING *;
-- If 0 rows: token consumed/expired/deleted, reject approval with 409 Conflict
```

Race between two simultaneous approvals: atomic UPDATE serializes; loser admin gets 409 → UI shows «Token has reached its usage limit».

### 4.7 TTL expiry cleanup

Daily Supabase cron (`expire_stale_join_requests`):
```sql
UPDATE join_requests SET status = 'expired'
WHERE status = 'pending'
  AND created_at < (
    SELECT expires_at FROM invite_tokens WHERE code = join_requests.code
  );
```
Edge Function variant for non-cron environments. Cleanup is non-blocking; expired requests just stop being actionable.

### 4.8 Token brute-force resistance

`code` ≈ 70 bits entropy (12 random base32 chars + 4 checksum chars; alphabet excludes I/L/O/U/0/1 to avoid visual confusion). Brute-force protected by RLS lookup rate-limit + token TTL (default 24h). Checksum chars enable client-side typo detection at paste time so the user sees «Invalid code» before hitting the server.

---

## 5. UI components — new + modified

### 5.1 New

| Component | Location | Purpose |
|---|---|---|
| `WorkspaceCreateSheet` (modify) | `Leaf/Views/Window/Settings/` | Add TTL preset + single-use default. No mode picker. |
| `GenerateInviteSheet` (rewrite) | `Leaf/Views/Window/Team/` | Optional label + TTL override + dual link/code output. Remove Paste Join code tab + Send template tab. |
| `ActiveTokensSection` | `Leaf/Views/Window/Settings/Workspace/` | List + copy + delete per token, bulk delete |
| `PendingRequestsSection` | `Leaf/Views/Window/Settings/Workspace/` | List + approve/decline + bulk actions + confirmation modals |
| `JoinWorkspaceByCodeSheet` | `Leaf/Views/Window/Settings/` | Invitee paste-code entry |
| `JoinRequestWaitingCard` | `Leaf/Views/Window/Settings/` | Sub-view of `AcceptInviteSheet` for closed-mode wait + cancellable state |
| `InviteTokensReader` | `Leaf/Models/` | @Observable wrapper around InviteTokenStore |
| `JoinRequestsReader` | `Leaf/Models/` | @Observable admin-side queue + invitee-side own-request status |
| `InviteTokenService` | `Packages/LeafCore/Sources/LeafCore/Team/` | Generate / list / delete tokens |
| `JoinRequestService` | `Packages/LeafCore/Sources/LeafCore/Team/` | Submit / cancel / approve / decline + ECDH+seal at approve, ECDH+unseal at success |

### 5.2 Modified

| Component | Change |
|---|---|
| `Sidebar` | Add `🔢 Join by code` row near `Join workspace` + pending-requests badge per workspace |
| `AcceptInviteSheet` | Dispatch by URL format: legacy v=1 with `?a=<admin_hex>` → existing S3 flow; new v=1 token-only → JoinRequestWaitingCard |
| `LeafWorkspaceSwitcher` | Per-row red badge for pending request count (admin view only) |
| `WindowSettingsView` | New `WorkspaceSettingsSection` sub-sections: Active tokens + Pending requests + Workspace default-TTL row |
| `InviteURLHandler` | Detect new token-only URL format; route to JoinRequestsReader.submit |

### 5.3 Removed

- `GenerateInviteSheet` «Paste Join code» tab — replaced by token generation flow.
- `GenerateInviteSheet` «Send template» tab — no longer needed (admin shares link directly, no asking invitee for code).
- `JoinTeamStepView` onboarding step's Join code display block — pivots to «Have an invite link or code? Paste it» entry. Existing `JoinCode.encode` stays for invitee-pubkey display in Settings → Account as low-priority «advanced» disclosure (Track 6 cleanup; not blocked by this redesign).

---

## 6. Notifications

Extend `notification_prefs` per-device row (Track 5 / S8 / M026) with new event types:

| Event | Default ON/OFF | Recipient | Trigger |
|---|---|---|---|
| `invite_request_received` | ON | admin | Invitee POSTs join_requests row (closed mode = only mode) |
| `invite_request_approved` | ON | invitee | Admin approves request |

**Not in MVP** (per Anton's §13 decisions):
- ~~`invite_request_declined`~~ — silent decline per §13.5; invitee UI updates via Realtime/poll without system push
- ~~`new_member_joined`~~ — admin already knows (they just approved) per §13.3
- ~~`invite_token_expired`~~ — too noisy; admin can check Active tokens list anytime

APNs categories:
- `leaf.invite.request` (admin-side) — actions `[Approve] [Decline]` (deep-link to PendingRequestsSection on tap)
- `leaf.invite.approved` (invitee-side) — no actions, tap deep-links to workspace if approved

**In-app:**
- Sidebar workspace-switcher row: red dot + count for admin's pending-requests
- Banner in TeamView header: «12 pending requests — Review» when count > 0
- Invitee's `JoinRequestWaitingCard` updates silently on status change via Realtime subscription or 30s poll

---

## 7. Default behaviors / settings

| Knob | Default | Override |
|---|---|---|
| Workspace mode at creation | closed (sole option in MVP) | — |
| Default invite TTL | 24 hours | TTL picker in `WorkspaceCreateSheet` |
| Default single-use | `false` (unlimited) | Toggle in `WorkspaceCreateSheet` |
| TTL options | 1h / 24h / 7d / 30d / Never expires | Hardcoded enum; «Never» = NULL `expires_at` |
| Max active tokens per workspace | 10 | Hardcoded; error on 11th generate attempt |
| Token code format | `LEAF-XXXX-XXXX-XXXX` (12 random base32 chars + 4 checksum, no I/L/O/U/0/1) | Single primitive; link path `leaf://invite/<code>` embeds the exact code — same string, two input methods |
| Token label | optional, empty default | Text input at generate time + edit in Active tokens list (post-MVP) |
| Invitee display name default | `NSFullUserName()` | Editable in preview card |
| Invitee can cancel pending request | yes | `[Cancel request]` button in waiting card |
| Cancellation notifies admin | no | Silent; admin queue just drops the row |
| Bulk approve | yes | `[Approve all]` confirmation modal → each invitee gets push |
| Bulk decline | yes | `[Decline all]` confirmation modal → silent (no pushes) |
| Approve notifies invitee | YES (APNs push) | Non-toggleable in MVP |
| Decline notifies invitee | NO (silent; UI updates via Realtime/poll) | Non-toggleable in MVP per §13.5 |
| Token delete notifies anyone | NO | Silent; future clicks fail at validation. Existing pending requests against deleted token: admin still sees + decides in queue (deletion ≠ purge of in-flight requests). |

---

## 8. Tier-gate interaction (existing T3-T4 substrate)

В MVP попасть в workspace можно **только** через invite — клик ссылки или ввод кода. Никакого отдельного «accept invite» action'а нет; submit-join-request это и есть единственный путь.

| Action | Free | Team |
|---|---|---|
| Create workspace | ❌ Upgrade modal | ✅ |
| Generate invite token (and delete it later) | ❌ (no workspace = no token) | ✅ |
| Join workspace via link or code (submit join request) | ❌ Upgrade modal | ✅ |
| Approve / Decline join requests as admin | ❌ (no workspace = no admin) | ✅ |
| Cancel own pending request | ✅ (anyone can withdraw their own request) | ✅ |

В MVP default tier = `team` (per Track 5 / S8 контракт §15.3 early-access). Free колонка — substrate для post-Stripe rollout; в MVP юзеры никогда не падают на Free, поэтому Upgrade modal'ы — это просто scaffolding, реальный UX не задеваюшие.

Tier gating enforced at action-handler level: existing `TierGate.canCreateWorkspace` / `canAcceptInvite` checks + new `TierGate.canApproveJoinRequest` (mirrors `canCreateWorkspace`).

---

## 9. Out of scope (post-launch / Track 6+)

Documented for future reference. Each is a deliberate non-decision.

### 9.1 Open mode (anyone-with-link-joins-instant)

Deferred per Anton's §13.1 decision («давай только закрытый»). Substrate is forward-compatible — adding open mode later requires:
- ALTER `workspaces` ADD COLUMN `mode` ('open' | 'closed') + ALTER `invite_tokens` ADD COLUMN `mode_snapshot` (captures token's mode at generation time, since workspace mode may change later)
- New Edge Function `auto_approve_open_join` that runs admin's approval logic server-side without admin's device involvement — requires either (a) admin pre-publishes encrypted teamKey blobs to a token-scoped pool, OR (b) a different crypto envelope where the token itself is the wrap-key seed
- UI: mode picker in WorkspaceCreateSheet + workspace Settings

Either path is whitepaper-level (admin can't be online to seal teamKey at every random click moment in open mode, so either pool-pre-seal or token-as-secret is needed). Park until post-launch product call.

### 9.2 Identity anchors beyond pubkey

- Email-domain allowlist (e.g. `@acme.com`) — admin filter by domain in pending queue
- Pre-allowlist by email list — admin paste 50 emails; only those can request
- Vouching by existing member — invitee picks vouching member; member confirms

These would close the «admin can't tell legit from spam in 50-person blind queue» gap. Each requires identity layer atop pubkey, which is a **whitepaper-level decision**. MVP ships pure pubkey + admin manual filter.

### 9.3 Bulk discovery
- Username/handle directory
- QR / NFC pairing for in-person bulk add

### 9.4 Spam protection
- Rate-limit per token (N requests/hour cap)
- Captcha on join request submission

### 9.5 Advanced lifecycle
- Token rotation (auto-rotate active tokens daily for paranoid mode)
- Geo/IP restrictions
- Multi-admin approval (N-of-M for high-security workspaces)

---

## 10. Acceptance gates (manual smoke)

Two-Mac signed-build session. Mac A = Алина (admin), Mac B = Боб (invitee).

| # | Scenario | Expected |
|---|---|---|
| **G1** | Generate invite + share link | Алина: `+ Generate invite` → TTL=24h → got link + code. Active tokens list shows 1. |
| **G2** | Closed-mode join via link | Боб clicks link in Slack → preview card → display name → `[Send request]` → waiting card. Алина gets push «Bob requested». |
| **G3** | Closed-mode join via code paste | Same end-state via Sidebar `🔢 Join by code` → paste `LEAF-XXXX-XXXX-XXXX` → waiting. |
| **G4** | Approve | Алина taps `[Approve]` on Bob → Bob gets push → app fetches blob → joined → TestRoom appears in Bob's workspace list. |
| **G5** | Decline (silent) | Алина taps `[Decline]` → request status flips → Bob's waiting card silently updates to «Request declined» on next state poll. NO system notification on Bob's Mac. |
| **G6** | Cancel pending request | Bob in waiting card taps `[Cancel request]` → Алина's queue refreshes → Bob's row gone. Алина got no notification. |
| **G7** | TTL expiry | Token with TTL=1 minute → wait 70 seconds → Bob clicks → preview shows «This invite has expired». Existing pending requests against same token: status flips to `expired` on next cron sweep. |
| **G8** | Delete before TTL | Алина deletes from Active tokens list → confirms modal → Bob clicks deleted link → «This invite no longer exists». |
| **G9** | Multiple active tokens | Алина generates 3 tokens (Team kickoff / Contractors / unlabeled single-use) → delete unlabeled → other two still accept new clicks. Active tokens list shows 2. |
| **G10** | Single-use token | Token `max_uses=1` → Bob joins (request approved) → Carol clicks same token → preview shows «This invite has reached its usage limit». |
| **G11** | Admin offline at invitee click | Алина closes Mac → Bob clicks link → request enters queue → Алина opens Mac next day → queue shows Bob → approve → Bob joins. Bob's app continues to poll while Алина offline; no broken state. |
| **G12** | Bulk approve | 5 pending requests → Алина `[Approve all]` → confirms modal → 5 sequential ECDH operations on Алина's Mac → all 5 invitees get push within ~5 seconds → all joined. |
| **G13** | Bulk decline (silent) | 5 pending requests → Алина `[Decline all]` → confirms modal → 5 status flips → NO pushes to any of the 5. They learn of decline via in-app Realtime/poll. |

---

## 11. Implementation phase breakdown

8 atomic commits in sequence. Plan-level detail comes in writing-plans-skill phase, not this spec.

1. **Schema M027 — local + Supabase** with stubs (pgTAP for RLS on `invite_tokens` + `join_requests`, Edge Functions skeleton 200-OK stubs)
2. **InviteToken value type + InviteTokenStore (local SQLCipher) + tests**
3. **InviteTokenService.generate / list / delete + tests** (no crypto — token is identifier only)
4. **Edge Functions: `create_join_request` / `cancel_join_request` (invitee side) + tests**
5. **Edge Functions: `approve_join_request` / `decline_join_request` / `delete_invite_token` / `expire_stale_join_requests` (admin + maintenance) + tests** — `approve_join_request` validates admin already populated `encrypted_team_key` on the row (server doesn't generate it; admin's local device does ECDH at click moment)
6. **JoinRequestService — submit (invitee) + approve (admin local ECDH-seal) + decline + cancel + tests**
7. **UI Phase A: WorkspaceCreateSheet update + GenerateInviteSheet rewrite + ActiveTokensSection**
8. **UI Phase B: PendingRequestsSection + JoinWorkspaceByCodeSheet + JoinRequestWaitingCard + Sidebar wiring + AcceptInviteSheet dispatch + notification integration + manual smoke checklist**

Build green at each commit. Full xcodebuild 5-scheme regression at each commit. SPM test suite stays green; new tests land alongside feature commit.

---

## 12. Migration / coexistence with S3 flow

- **Generation side:** new code path writes to `invite_tokens` + creates request-flow invites. Old `InviteService.generateInvite(workspaceID:inviteePubkeyHex:requireOTP:)` removed from public UI; kept in LeafCore as `@available(*, deprecated)` for any deep-link landing on the old AcceptInviteSheet path during the back-compat window.
- **Acceptance side:** `AcceptInviteSheet` URL dispatch:
  - URL with `?a=<64-hex>` query param → S3 v=1 path (existing flow — invitee pubkey is known to admin upfront, instant decrypt)
  - URL WITHOUT `?a=` query param OR `?` segment → new request flow → JoinRequestWaitingCard
  - `LEAF-XXXX-XXXX-XXXX` code → new request flow only (no S3-style code format existed)
- **Sunset:** 30 days post-ship, delete S3 generation code path entirely. Keep S3 acceptance for another 30 days (users may still have unaccepted S3 invites). After day 60, drop `pending_invites` table in cleanup migration.

---

## 13. Open questions — RESOLVED (Anton review 2026-05-20)

| # | Question | Decision |
|---|---|---|
| 13.1 | Open mode trade-off or closed-only MVP? | **Closed only.** Open mode → §9.1 post-launch. |
| 13.2 | Email anchor (§9.2) — out of scope or revisit? | **Out of scope.** «email ни на что не влияет.» |
| 13.3 | `new_member_joined` push to admin? | **No push.** «админу пуш не нужен потому что для МВП только закрытые» — admin already knows from their own Approve action. |
| 13.4 | Per-token label — required or optional? | **Optional.** Empty label → «Untitled token #<short hash>» auto-display. |
| 13.5 | Bulk decline — push to declinees? | **Asymmetric.** Approve → push (so invitee learns the good news). Decline → silent (invitee app updates via Realtime/poll without system notification). |

---

## 14. Self-review checklist

- ✅ No placeholders / TBD outside «Branch: TBD» (intentional — branch chosen at plan time)
- ✅ Schema and RLS policies named explicitly
- ✅ UX walkthrough covers all 5 paths (admin create / admin generate / invitee request / admin approve+decline+manage / admin tokens)
- ✅ Crypto section is self-contained engineering reference, marked as such; reuses S3 v=1 envelope — no whitepaper change
- ✅ Migration plan + deprecation window stated
- ✅ Out-of-scope explicit (§9)
- ✅ 13 acceptance gates concrete + measurable
- ✅ Implementation phases atomic (each commit builds green)
- ✅ Tier-gate integration unambiguous (§8 table — simplified per v3 amendment: no separate «accept invite» action)
- ✅ Notification + APNs categories enumerated; ABSENT pushes (decline, new_member, expire) explicitly listed as «not in MVP»
- ✅ Default settings table complete (§7)
- ✅ All 5 §13 open questions resolved
- ✅ v3 amendments applied: token = code (single primitive, URL embeds it), `Revoke` → `Delete` in UI + Edge Function, §8 tier table simplified to 5 unambiguous rows
