# Track 5 / S8 — Polish + Settings Restructure

**Status:** Draft (2026-05-19). Closes Track 5 collaboration redesign.
**Owner:** Local Claude (Mac).
**Branches:**
- `feature/track-5-S8-polish-settings` (this branch, off `feature/track-5-S7-team-ui`).
- `feature/track-5-S7-team-ui` receives one pre-S8 hot-fix commit (JWT refresh).
- `gundemtech/leaf-relay` parallel branch `feature/track-5-S8-polish-settings` (off S6 `144a73d` or S7 equivalent).

**Contract:** `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md` (§10 Notifications, §13 Retention, §15 Tier-gating, §16 OQ-T5-1/-2/-6).

**Reference patterns:**
- S5 spec — `ShareRulesStore` normalized per-row pattern, `TeamEventBroadcastService` actor + tick driver, denylist regression fence.
- S7 spec — Reader/Service split, env-injection composition root, Realtime substrate (Phoenix WS + 30s polling fallback), `DispatchCoverageTests` parity fence.
- Track 1 D3 — structured MCP tool pattern (`QueryActivityTool` / `GetDecisionTool`).

---

## 1. Goal — fitness function

S8 is **done** when, on `feature/track-5-S8-polish-settings`:

1. **UC-T5-2 AI half** — Mac B Cursor/Claude Code calls `leaf_query_team(member="anton")` → returns structured timeline JSON. Member resolution local-only. Sentinel fence asserts payload contains no banned keys.
2. **UC-T5-3 reply path** — APNs Handoff push delivers ≤5s warm. `dm.reply` action deep-links Mac B → activates workspace → scrolls to message → focuses reply textfield.
3. **UC-T5-4 mark-done path** — APNs Task push `dm.markDone` action → local mirror UPDATE optimistically + PATCH server + retry queue on network failure; notification dismisses.
4. **UC-T5-7 tier gate** — Dev/QA flips `UserDefaults["tier"]` = `"free"` → Team tab shows mockup-preview + Upgrade CTA → workspace creation / DM send / invite acceptance blocked with UpgradeModal.
5. **Realtime push live** — Mac A sends DM → Mac B receives via Realtime push within ≤5s (NOT 30s polling fallback). Decryption succeeds via real `TeamEventBlobCodec` / `DirectMessageBlobCodec` injection.
6. **JWT long-session** — Mac B Realtime channel stays alive >1h via in-place `access_token` rotation (no reconnect storm).
7. **Hard-wipe + 30d pruner** — Settings → Workspace → «Wipe cache data» destructive button cascades local mirror tables + keystore (preserves team_keys/team_members audit invariant). Daily pruner auto-wipes workspaces past `left_at_ms + 30d`.
8. **Settings restructure** — 10 sections, Account at top, Notifications (4 sub-groups, 11 prefs), Privacy «Keep last N days» picker.
9. **All 5 xcodebuild schemes green** + LeafCore SPM regression: 0 failures.

Manual smoke (G22) deferred to two-Mac signed-build session alongside G15+G16/G18/G19/G21 per Track 5 collective acceptance gate.

---

## 2. Scope

### 2.1 IN S8 (14 atomic commits + 1 pre-S8 commit)

| # | Item | UC link | Discovery basis |
|---|---|---|---|
| **P1** | Pre-S8 on S7 branch — JWT in-place refresh via Phoenix `access_token` frame | UC-T5-3/-4/-6 (Realtime stability) | `RealtimePhoenixMessage.makeAccessTokenRefresh` already exists |
| **T0** | Phase H Realtime decryption wiring + `EncryptedRow` compile-time struct (A-I4 structural fix) | UC-T5-2/-3 | LeafApp.swift:287-301 stubs throw NSError |
| **T1** | M026 local migration — `notification_prefs` + ALTER `messages_mirror.pending_mark_done` + `NotificationPrefsStore` + tests | UC-T5-3/-4 | Mirror `ShareRulesStore` pattern |
| **T2** | M026 Supabase migration — `waitlist` table + `notification_prefs` server mirror + Auth Hook `tier` claim stub + pgTAP | UC-T5-7 | Existing `auth.jwt() ->> 'pubkey'` pattern |
| **T3** | `TierGate` struct + `Tier` enum + `TierGateReader` + UpgradeModal per-callsite scaffold | UC-T5-7 | `ShareRulesStore` pattern (NOT actor) |
| **T4** | Tier-gate wiring (WorkspaceCreateSheet / SendDirectMessageSheet / AcceptInviteSheet) + Free-state mockup feed + Free-state sidebar | UC-T5-7 | Default tier="team" → MVP user никогда не Free |
| **T5** | APNs categories (3) + actions (`dm.reply` / `dm.markDone`) + thread-id `<wid>:<kind>` + `apns_push` Edge Function update + `notification_prefs` server read | UC-T5-3/-4 | S4 thread-id already wired |
| **T6** | AppDelegate action handlers + `WindowState.focusReplyField` + `pending_mark_done` retry queue from RootView .task tick | UC-T5-3/-4 | Existing tickOnce + scroll + pulse infra |
| **T7** | `leaf_query_team(member:)` MCP tool + `TeamTimelineQueryService` (LeafCore/Team/) + sentinel regression fence + tests | UC-T5-2 | `GetCurrentPresenceTool` Codable pattern |
| **T8** | `WorkspaceCascadeDeleter` (manual + auto pruner) + `WorkspaceReader.hardDelete` + `WorkspaceService.hardDelete` + WorkspaceHardWipeConfirmationModal + lifecycle event stream | S7 C-I7 promise | `TeamEventMirrorRetentionPruner` precedent |
| **T9** | AccountSettingsSection + NotificationsSettingsSection (4 sub-groups, 11 prefs) + WindowSettingsView reordering | UX | Mirror `ShareControlsSettingsSection` |
| **T10** | PrivacySettingsSection «Keep last N days» picker + retention config + wire to existing `MirrorRetentionPruner` | Contract §13:479 | S5 deferred this to S8 |
| **T11** | B-I4 — refactor impl `FeedItem.grouped(kind: ShareSource)` → `kind: String` per S7 spec §11.0:575 | doc parity | Impl drifted from spec |
| **T12** | Contract amendments — §10.3 add `category` field; §15.1 `Tier { free, team }` (NOT `pro`) | doc | Cross-spec reviewer CRIT-4 + IMP-1 |
| **T13** | Composition root wiring + `current-state.md` update + ship commit `docs(shared): Track 5 / S8 landed` | ship | n/a |

### 2.2 OUT (defer Track 6 / post-launch)

- **Member promote/demote** — Supabase ADD COLUMN role + UPDATE RLS + admin UI; single-creator-admin works для MVP per контракт §14.1.
- **C-I2 / C-I3** — [+ Send] recipient picker variant + «Send first message» empty-state CTA; UX polish, не UC.
- **Reply inline в feed** (без открытия modal sheet) — Track 6.
- **Notifications coalescing impl** — toggle reads as default-ON but coalescing logic is Track 6.
- **Onboarding tier-fork** — needed когда default tier flips Free post-Stripe-launch; пока default="team" MVP не нуждается.
- **Stripe wire-up + actual entitlement enforcement** — separate post-launch track per контракт §15.3.
- **Full account wipe** (team_keys + team_members) — Track 6 «Remove account» flow.
- **Settings tab-style navigation** (macOS native System Settings) — out of scope.
- **iCloud sync of preferences** — out of MVP.
- **Per-recipient share rules** — Track 6 v1.1.

---

## 3. Architecture deltas

### 3.1 Tier gate

```
┌──────────────────────────────────────────────────────────────────────┐
│  Tier check at UI boundaries (MVP — honor-system)                    │
│                                                                       │
│  UserDefaults["tier"] = "free" | "team"  (default "team" MVP)         │
│       │                                                                │
│       ▼                                                                │
│  TierGate.current() → Tier     (pure struct, sync read)                │
│       │                                                                │
│       ▼                                                                │
│  TierGateReader (@MainActor @Observable) → UI binding                  │
│       │                                                                │
│       ├─→ WorkspaceCreateSheet.[Create]  disabled when .free          │
│       ├─→ SendDirectMessageSheet.[Send] disabled when .free          │
│       └─→ AcceptInviteSheet.[Join]      → UpgradeModal when .free    │
│                                                                       │
│  Server-side scaffolding (advisory-mode in MVP, enforce post-Stripe): │
│       Auth Hook injects `tier` JWT custom claim (always "team")       │
│       RLS policies on direct_messages_member_write / workspaces_admin │
│       reference `auth.jwt() ->> 'tier' = 'team'` — logged not blocked │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Phase H Realtime decryption (T0)

```
┌──────────────────────────────────────────────────────────────────────┐
│  LeafRealtimeService.handleTeamEventInsert(row: SupabaseTeamEventRow)│
│       │                                                                │
│       ▼                                                                │
│  Extract EncryptedTeamEventInput from row                              │
│  ┌───────────────────────────────────────────────────────────┐         │
│  │  {workspaceID, encryptedPayload, keyID, aadInputs}         │  ←─── No senderPubkeyHex/kind/replyTo (compile-time fence) │
│  └───────────────────────────────────────────────────────────┘         │
│       │                                                                │
│       ▼                                                                │
│  injectedDecryptor(EncryptedTeamEventInput) → TeamEventPlaintext       │
│       (calls TeamEventBlobCodec.decode via keystore.readTeamKey)       │
│       │                                                                │
│       ▼                                                                │
│  Service constructs TeamEventMirrorRow with both inputs:                │
│  ├─→ RLS-attested fields (row.senderPubkeyHex, workspaceID, etc)       │
│  └─→ plaintext fields (kind, replyTo, payload)                          │
│       │                                                                │
│       ▼                                                                │
│  C2/C3 trust gates verify plaintext consistency vs RLS-attested        │
│       │                                                                │
│       ▼                                                                │
│  UPSERT messages_mirror / team_events_mirror                            │
└──────────────────────────────────────────────────────────────────────┘
```

`decryptOnly(_:)` methods extracted as public api on existing services (`TeamEventMirrorService` + `DirectMessageInboxService`) — same logic used by 30s polling fallback. Realtime path injects these via closures. Polling fallback remains as safety net.

### 3.3 JWT in-place refresh (P1, pre-S8)

```
┌──────────────────────────────────────────────────────────────────────┐
│  LeafRealtimeService owns 50-min refresh timer                         │
│       │                                                                │
│       ▼                                                                │
│  Timer fires (or per-attempt before reconnect):                        │
│       │                                                                │
│       ▼                                                                │
│  Compute refresh threshold:                                            │
│       refresh_needed = exp - now < 60s OR                              │
│                        last_refresh + 55min < now                      │
│       (handles NTP drift + asleep-overnight clock skew)                │
│       │                                                                │
│       ▼                                                                │
│  SupabaseClient.ensureFreshSession() → fresh JWT                       │
│       │                                                                │
│       ▼                                                                │
│  Driver.refreshAccessToken(jwt) — sends RealtimePhoenixMessage         │
│       .makeAccessTokenRefresh(topic:, ref:, accessToken:)               │
│       (Phoenix in-place rotation, NO reconnect cycle)                  │
└──────────────────────────────────────────────────────────────────────┘
```

NO actor cycle: `RealtimeWebSocketDriver` does NOT import `SupabaseClient`. Service is the orchestrator; driver receives fresh JWT injected via method call.

### 3.4 Hard-wipe + auto-pruner pair

```
┌──────────────────────────────────────────────────────────────────────┐
│  Manual hard-wipe (Settings → Workspace → «Wipe cache data»):        │
│       │ (only enabled when workspace.left_at_ms != nil OR             │
│       │  deleted_at_ms != nil)                                        │
│       ▼                                                                │
│  WorkspaceHardWipeConfirmationModal (type-name, NFC normalize)         │
│       │                                                                │
│       ▼                                                                │
│  WorkspaceReader.hardDelete(workspaceID:) → @MainActor                 │
│       │                                                                │
│       ▼                                                                │
│  WorkspaceCascadeDeleter.execute(workspaceID:) → actor                 │
│       │                                                                │
│       ├─→ Single writeSQL transaction:                                 │
│       │   DELETE FROM messages_mirror WHERE workspace_id = ?           │
│       │   DELETE FROM team_events_mirror WHERE workspace_id = ?        │
│       │   DELETE FROM share_rules WHERE workspace_id = ?                │
│       │   DELETE FROM team_event_broadcast_offsets WHERE workspace_id  │
│       │   DELETE FROM pending_invites WHERE workspace_id = ?           │
│       │   DELETE FROM workspaces WHERE id = ?  (NOT soft-mark)         │
│       │   -- NOTE: cross_post_log lives Supabase-side only; no local    │
│       │   --       table to wipe (server retention pruner handles it)   │
│       │                                                                │
│       ├─→ KEEP team_keys (audit invariant per WorkspaceService:168)    │
│       ├─→ KEEP team_members (audit invariant)                           │
│       │                                                                │
│       └─→ TeamKeystore.deleteWorkspace(workspaceID:)                   │
│              rm -rf <root>/workspaces/<wid>/                            │
│                                                                       │
│       (After cascade: WorkspaceReader emits lifecycleEvent stream;      │
│        TeamFeedReader / DirectMessageInboxReader observe + refresh.)    │
│                                                                       │
│  Auto-pruner (daily tick from RootView .task):                          │
│       │                                                                │
│       ▼                                                                │
│  WorkspaceCascadeDeleter.pruneExpiredLeftWorkspaces():                  │
│       SELECT id FROM workspaces                                         │
│         WHERE left_at_ms < now - 30 days                                │
│            OR deleted_at_ms < now - 30 days                             │
│       For each match → execute(workspaceID:) (same path as manual)     │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.5 APNs UX uplevel

```
┌──────────────────────────────────────────────────────────────────────┐
│  LeafAppDelegate.applicationDidFinishLaunching:                        │
│       UNUserNotificationCenter.setNotificationCategories({              │
│           UNNotificationCategory(id: "leaf.dm.handoff",                 │
│               actions: [reply, markRead],                              │
│               options: [.customDismissAction]),                        │
│           UNNotificationCategory(id: "leaf.dm.task",                   │
│               actions: [reply, markDone],                              │
│               options: [.customDismissAction]),                        │
│           UNNotificationCategory(id: "leaf.dm.ping",                   │
│               actions: [reply],                                        │
│               options: [.customDismissAction]),                        │
│       })                                                                │
│                                                                       │
│  apns_push Edge Function payload extension:                            │
│       aps.category = "leaf.dm.<kind>"   (NEW per contract amend §10.3)│
│       aps.thread-id = "<workspace_id>:<kind>"  (was just workspace_id)│
│       Read notification_prefs row pre-send;                            │
│       Skip if prefs.<kind>.enabled = false                              │
│                                                                       │
│  Action handlers:                                                      │
│       dm.reply  → deep-link + WindowState.focusReplyField = true       │
│       dm.markDone → local mirror UPDATE done_at=now (optimistic) +     │
│                     supabase PATCH; on network fail → set              │
│                     messages_mirror.pending_mark_done = 1;             │
│                     RootView .task tick retries pending_mark_done rows │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 4. Component breakdown

### 4.1 New files

**Source modules:**
1. `Packages/LeafCore/Sources/LeafCore/Tier/Tier.swift` — `enum Tier: String { case free, team }` (matching contract §15.1).
2. `Packages/LeafCore/Sources/LeafCore/Tier/TierGate.swift` — `struct TierGate { static func current() -> Tier; static func canCreateWorkspace() -> Bool; static func canSendDM() -> Bool; static func canAcceptInvite() -> Bool; static func setTier(_:); static let key = "tier" }`.
3. `Leaf/Models/TierGateReader.swift` — `@MainActor @Observable final class TierGateReader { var tier: Tier; init observes UserDefaults change notifications }`.
4. `Leaf/Views/Tier/UpgradeModal.swift` — `struct UpgradeModal: View` with email field + POST + success/error toast. Reused per call-site via `.sheet(isPresented:)`.
5. `Leaf/Views/Window/Settings/AccountSettingsSection.swift` — display name editor + pubkey copy + Tier chip + (when free) Upgrade button.
6. `Leaf/Views/Window/Settings/NotificationsSettingsSection.swift` — 4 SwiftUI `Section` sub-groups × 11 toggles total.
7. `Packages/LeafCore/Sources/LeafCore/Team/TeamTimelineQueryService.swift` — actor with `query(member:, since:, until:, kinds:, limit:) -> TeamTimelineResult`.
8. `Packages/LeafMCP/Tools/QueryTeamTool.swift` — MCP tool wraps service + sentinel-injection regression test.
9. `Packages/LeafCore/Sources/LeafCore/Team/WorkspaceCascadeDeleter.swift` — actor with `execute(workspaceID:)` and `pruneExpiredLeftWorkspaces()`.
10. `Leaf/Views/Window/Settings/WorkspaceHardWipeConfirmationModal.swift` — type-name (NFC normalize) friction.
11. `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M026_S8Substrate.swift` — creates `notification_prefs` + ALTER `messages_mirror ADD COLUMN pending_mark_done`.
12. `Packages/LeafCore/Sources/LeafCore/DB/NotificationPrefsStore.swift` — mirrors `ShareRulesStore` (normalized per-row + defaults map fallback).
13. `Packages/LeafCore/Sources/LeafCore/Team/NotificationKind.swift` — `enum NotificationKind: String, CaseIterable { case handoff, task, ping, decision, blocker, openQuestion, whereStopped, rawActivity, respectFocus, coalesce, sound }` + per-kind `displayLabel: String` mapping (cross-spec MIN-1 bridge).
14. `Packages/LeafCore/Sources/LeafCore/Network/EncryptedRow.swift` — `struct EncryptedTeamEventInput { workspaceID: String; encryptedPayload: Data; keyID: UUID; aadInputs: AAD }` + same for DM. Constructed from `SupabaseTeamEventRow` via narrow extractor. Decryptor signature restricted to this type only.
15. `Leaf/Views/Window/Team/TeamFeedFreePreview.swift` — mockup feed component для Free state Team tab.

**Edge Function changes:**
- `supabase/functions/apns_push/index.ts` — body extension: `aps.category`, `aps.thread-id` format change, `notification_prefs` server read pre-send.

**Supabase migration:**
- `supabase/migrations/20260519120000_s8_substrate.sql` — `waitlist (email PK, source, created_at)` + RLS `INSERT WITH CHECK true` for anon + `notification_prefs` mirror table + `custom_access_token_hook` extension injecting `tier` claim.

**pgTAP:**
- `supabase/tests/database/210_waitlist_anon_insert.test.sql` — anon INSERT allowed + SELECT denied + duplicate email idempotent.
- `supabase/tests/database/220_notification_prefs_self_rw.test.sql` — owner read/write OK + cross-pubkey denied.
- `supabase/tests/database/230_tier_claim_injection.test.sql` — Auth Hook with tier claim → JWT contains "tier": "team".

### 4.2 Edited files

- `Leaf/LeafApp.swift` — Phase H wiring (real decryptors), composition root: TierGateReader, NotificationPrefsReader, WorkspaceCascadeDeleter, daily-pruner tick.
- `Leaf/LeafAppDelegate.swift` — APNs categories registration in `applicationDidFinishLaunching`, action handlers `dm.reply` / `dm.markDone`.
- `Leaf/Models/WindowState.swift` — add `var focusReplyField: Bool = false` (toggled by `dm.reply`, cleared by TeamView).
- `Packages/LeafCore/Sources/LeafCore/Network/SupabaseClient.swift` — add `ensureFreshSession() -> SupabaseAuthSession` with NTP-skew-tolerant threshold. NO new actor cycle.
- `Packages/LeafCore/Sources/LeafCore/Network/RealtimeWebSocketDriver.swift` — add `refreshAccessToken(_ jwt: String) async` method using `RealtimePhoenixMessage.makeAccessTokenRefresh` frame.
- `Packages/LeafCore/Sources/LeafCore/Network/LeafRealtimeService.swift` — own 50min refresh timer; per-attempt refresh check pre-reconnect; phase H injection points.
- `Packages/LeafCore/Sources/LeafCore/Team/TeamEventMirrorService.swift` — extract `decryptOnly(_:)` public method.
- `Packages/LeafCore/Sources/LeafCore/Team/DirectMessageInboxService.swift` — extract `decryptOnly(_:)` public method.
- `Packages/LeafCore/Sources/LeafCore/Team/TeamFeedItem.swift` — refactor `case grouped(kind: String, ...)` per S7 spec §11.0:575 (B-I4).
- `Packages/LeafCore/Sources/LeafCore/Team/TeamFeedQueryService.swift` — update grouping to use raw event_kind (cross-spec IMP-3).
- `Packages/LeafCore/Sources/LeafCore/Team/Reader/TeamFeedReader.swift` — adjust `applyGrouping` consumer.
- `Leaf/Views/Window/Team/LeafFeedRow.swift` — `kind: String` parameter consumer.
- `Leaf/Views/Window/Team/TeamView.swift` — Free-state branching to `TeamFeedFreePreview`; focusReplyField observer.
- `Leaf/Views/Window/Settings/WorkspaceSettingsSection.swift` — add «Wipe cache data» button (only when workspace.leftAt != nil OR deletedAt != nil) → WorkspaceHardWipeConfirmationModal.
- `Leaf/Views/Window/Settings/WindowSettingsView.swift` — reorder: Account → Workspace → Share → Notifications → Privacy → Background → Folders → LocalApps → SystemObservers → Updates.
- `Leaf/Views/Window/Settings/PrivacySettingsSection.swift` — expand from stub: «Keep auto-shared events for [picker: 30/60/90/180/365] days» + read-only deny-list per S5 §11.1 + wire to MirrorRetentionPruner config.
- `Leaf/Views/Modals/WorkspaceCreateSheet.swift` — TierGate check on [Create].
- `Leaf/Views/Modals/SendDirectMessageSheet.swift` — TierGate check on [Send].
- `Leaf/Views/Modals/AcceptInviteSheet.swift` — TierGate check on [Join] → UpgradeModal when free.
- `Leaf/Views/Window/Sidebar.swift` — Free-state empty workspace switcher with «Upgrade to add workspaces» row.
- `Packages/LeafCore/Sources/LeafCore/Team/WorkspaceReader.swift` — add `hardDelete(workspaceID:) async -> String?` (returns per-op error or nil). Emit `lifecycleEvent` stream.
- `Packages/LeafCore/Sources/LeafCore/Team/WorkspaceService.swift` — add `hardDelete(workspaceID:)` (writeSQL transaction for cascade DELETE; preserves team_keys/team_members per audit invariant).
- `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` — add `notification_prefs` enum + `messages_mirror.pendingMarkDone` constant.
- `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md` — amendments §10.3 (add category) + §15.1 (Tier "free"|"team") with `> **Amendment 2026-05-19 (S8 spec):**` annotations.
- `docs/superpowers/specs/2026-05-16-track-5-S7-team-ui.md` — amendment for `FeedItem.grouped` decision if impl-side wins (per B-I4 outcome — current spec wins, impl refactors).

### 4.3 Hard-delete cascade — exact SQL

```sql
BEGIN;
DELETE FROM messages_mirror WHERE workspace_id = ?;
DELETE FROM team_events_mirror WHERE workspace_id = ?;
DELETE FROM share_rules WHERE workspace_id = ?;
DELETE FROM team_event_broadcast_offsets WHERE workspace_id = ?;
DELETE FROM pending_invites WHERE workspace_id = ?;
DELETE FROM workspaces WHERE id = ?;
-- KEEP team_keys (audit invariant) — keystore files wiped separately
-- KEEP team_members (audit invariant)
COMMIT;
-- Then (outside transaction):
TeamKeystore.deleteWorkspace(workspaceID:)  -- rm -rf <root>/workspaces/<wid>/
```

---

## 5. New schema

### 5.1 Local M026 (`M026_S8Substrate.swift`)

```swift
// Step 1: notification_prefs (mirror ShareRulesStore pattern — normalized per-row)
try db.create(table: "notification_prefs", body: { t in
    t.primaryKey(["pref_kind"])  // device-wide preferences (no workspace_id)
    t.column("pref_kind", .text).notNull()
    t.column("enabled", .integer).notNull().defaults(to: 1)
    t.column("updated_at_ms", .integer).notNull()
})

// Step 2: extend messages_mirror with pending_mark_done flag
try db.alter(table: "messages_mirror", body: { t in
    t.add(column: "pending_mark_done", .integer).notNull().defaults(to: 0)
})

// Step 3: partial index for retry queue scan
try db.create(
    index: "idx_messages_mirror_pending_mark_done",
    on: "messages_mirror",
    expressions: [Column("pending_mark_done")],
    condition: Column("pending_mark_done") == 1
)
```

**NO local schema for tier** — UserDefaults-only per контракт §15.1.
**NO local schema for "Keep N days"** — UserDefaults-only (simple int slider).
**NO local audit log** for wipes (out of scope).

### 5.2 Supabase M026 (`20260519120000_s8_substrate.sql`)

```sql
-- waitlist (anon INSERT allowed; nothing else)
CREATE TABLE waitlist (
  email      text PRIMARY KEY CHECK (email ~* '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'),
  source     text NOT NULL DEFAULT 'upgrade_modal',
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE waitlist ENABLE ROW LEVEL SECURITY;
CREATE POLICY waitlist_anon_insert ON waitlist FOR INSERT WITH CHECK (true);
-- No SELECT policy → reads denied for everyone (anon, authenticated, service_role can bypass via direct DB)

-- notification_prefs (per-pubkey mirror of local)
CREATE TABLE notification_prefs (
  pubkey     text NOT NULL,
  pref_kind  text NOT NULL,
  enabled    boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (pubkey, pref_kind)
);
ALTER TABLE notification_prefs ENABLE ROW LEVEL SECURITY;
CREATE POLICY notification_prefs_self_rw ON notification_prefs FOR ALL
  USING (pubkey = auth.jwt() ->> 'pubkey')
  WITH CHECK (pubkey = auth.jwt() ->> 'pubkey');
CREATE INDEX idx_notification_prefs_pubkey ON notification_prefs(pubkey);

-- Auth Hook extension — inject tier claim into JWT
-- (Replaces existing custom_access_token_hook function from M011)
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
  RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = public AS $$
DECLARE
  claims jsonb;
  user_pubkey text;
  user_tier text;
BEGIN
  claims := COALESCE(event->'claims', '{}'::jsonb);
  -- existing pubkey claim
  SELECT pubkey INTO user_pubkey FROM pubkey_registry
    WHERE auth_id = (event->>'user_id')::uuid;
  IF user_pubkey IS NOT NULL THEN
    claims := jsonb_set(claims, '{pubkey}', to_jsonb(user_pubkey));
  END IF;
  -- new tier claim (MVP: always "team" for early-access; future: read from entitlements table)
  user_tier := 'team';
  claims := jsonb_set(claims, '{tier}', to_jsonb(user_tier));
  RETURN jsonb_set(event, '{claims}', claims);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook(jsonb) TO supabase_auth_admin;
```

---

## 6. Privacy walkback fences

### 6.1 leaf_query_team output sentinel fence (sec C5)

New regression test `QueryTeamToolPayloadLeakageTests.swift`:
- Inject team_events_mirror row with payload containing every banned key: `ai_request_id`, `ai_prompt`, `ai_response`, `body`, `body_kind`, `email_subject`, `note_body`, `file_contents`, `preview`, raw `senderPubkey`, raw GPG signing key, etc.
- Call `leaf_query_team` → assert response JSON does NOT contain ANY banned-key substring at ANY position в tree.
- Test for both `gitCommits` / `linearIssues` / `detectedDecisions` / etc. allowlisted sources.

### 6.2 Hard-wipe verification (sec C2)

New regression test `WorkspaceCascadeDeleterAuditInvariantTests.swift`:
- Setup workspace + members + team_keys + mirror data.
- Call `execute(workspaceID:)`.
- Assert: messages_mirror/team_events_mirror/share_rules/offsets ALL empty for that workspace.
- Assert: team_keys rows for that workspace STILL EXIST (audit invariant).
- Assert: team_members rows for that workspace STILL EXIST (audit invariant).
- Assert: keystore folder `<root>/workspaces/<wid>/` no longer exists.
- Assert: workspaces row DELETED.

### 6.3 Phase H decryptor structural fence (sec I4)

`EncryptedTeamEventInput` and `EncryptedDirectMessageInput` types have NO senderPubkeyHex / kind / replyTo fields. Compile-time enforcement — decryptor signature `(EncryptedTeamEventInput) async throws -> TeamEventPlaintext` cannot access these. Test `EncryptedRowShapeTests.swift` asserts the type contract via reflection.

### 6.4 APNs notification_prefs server filter

`apns_push` Edge Function reads `notification_prefs` row for recipient pubkey + pref_kind matching message kind. If `enabled = false` → skip push (return `{ok: true, devices_pushed: 0, skipped_by_prefs: true}`). Tested in Deno integration test.

---

## 7. Test plan

### 7.1 New SPM test files

| File | Coverage |
|---|---|
| `TierGateTests` | static read, default value "team", canCreateWorkspace/canSendDM/canAcceptInvite per tier |
| `TierGateReaderTests` | UserDefaults change observation, @Observable invalidation |
| `NotificationPrefsStoreTests` | normalized per-row CRUD, defaults map fallback, ALTER-resistant pattern |
| `M026_S8SubstrateTests` | migration regression (notification_prefs creation, ALTER messages_mirror.pending_mark_done, partial index) |
| `WorkspaceCascadeDeleterTests` | execute cascade DELETE single transaction, audit invariant preserved (team_keys/members), keystore wipe via mock |
| `WorkspaceCascadeDeleterAuditInvariantTests` | 6.2 fence |
| `WorkspaceCascadeDeleterPrunerTests` | prune fires only when left_at_ms/deleted_at_ms past 30d; idempotent; rejoin race (cosmetic OK) |
| `WorkspaceReaderHardDeleteTests` | error propagation, lifecycleEvent stream emit |
| `EncryptedRowShapeTests` | 6.3 fence via reflection |
| `TeamEventMirrorServiceDecryptOnlyTests` | extracted public method, plaintext / RLS-attested separation |
| `DirectMessageInboxServiceDecryptOnlyTests` | same |
| `LeafRealtimeServiceDecryptorWiringTests` | inject mock decryptor, verify call path |
| `LeafRealtimeServiceJWTRefreshTests` | 50min timer fires, per-attempt check pre-reconnect, NTP skew threshold |
| `SupabaseClientEnsureFreshSessionTests` | exp < 60s OR last_refresh + 55min < now, race coalesce |
| `RealtimeWebSocketDriverRefreshAccessTokenTests` | sends Phoenix access_token frame, no reconnect |
| `TeamTimelineQueryServiceTests` | member resolution (pubkey hex / display_name / ambiguous error), bounds (limit 100/500), kind filter, sender_pubkey != self filter |
| `QueryTeamToolTests` | MCP tool invocation, Codable JSON shape |
| `QueryTeamToolPayloadLeakageTests` | 6.1 fence |
| `AppDelegateAPNsCategoriesTests` | category registration, action handler dispatch |
| `DirectMessageInboxReaderRetryPendingMarkDoneTests` | retry on next tick, success clears flag, permanent failure silent |
| `WindowStateFocusReplyFieldTests` | toggle/clear |
| `NotificationKindDisplayLabelTests` | each kind has mapping |
| `TeamFeedReaderApplyGroupingStringKindTests` | B-I4 refactor, grouping uses raw event_kind not ShareSource |

### 7.2 pgTAP test files (Supabase)

- `210_waitlist_anon_insert.test.sql` — anon INSERT OK; SELECT denied; duplicate email INSERT idempotent (PK conflict surfaces as 409 — client handles).
- `220_notification_prefs_self_rw.test.sql` — owner CRUD OK; cross-pubkey 0 rows.
- `230_tier_claim_injection.test.sql` — Auth Hook input → output contains `claims.tier = "team"`.

### 7.3 Deno tests (Edge Function)

- `supabase/functions/apns_push/test.ts` extension — notification_prefs disabled = skip; enabled = push; category field present; thread-id format = `<wid>:<kind>`.

### 7.4 Integration tests (LeafCorePrivate moat)

- `RealtimeDecryptionEndToEndIntegrationTests` (gated behind `LEAF_RUN_INTEGRATION=1`) — real codec round-trip Realtime → decrypted → mirror UPSERT.
- `JWTRefreshLongSessionIntegrationTests` — mock 1h+ session, verify Realtime channel survives.

---

## 8. Manual smoke (G22) — two-Mac signed build

Deferred to acceptance-gate session alongside G15+G16/G18/G19/G21.

10 steps + 4 negative paths:

**Golden path:**
1. Anton Mac A: `defaults read tech.gundem.leaf tier` → `team` (default). Settings → Account section shows «Team — early access» chip.
2. Anton sends Handoff DM to Dima. Dima Mac B receives APNs banner ≤5s warm (Realtime path) with «Anton sent a handoff» title + actions [Reply] [Mark Read].
3. Dima clicks [Reply] → Leaf opens → Team tab activates → scrolls to handoff card with 2s highlight pulse → reply textfield focused. Dima types reply → Send.
4. Anton receives Dima's reply via Realtime ≤5s + APNs banner.
5. Anton sends Task DM to Dima. Dima sees APNs banner with [Reply] [Mark Done].
6. Dima clicks [Mark Done] (no app open) → notification dismisses → Anton sees task strikethrough + «Done by Dmitrii» in feed ≤30s.
7. Toggle Notification Center → see DM notifications grouped by `<wid>:<kind>` (handoff/task/ping separate stacks per workspace).
8. Cursor: `?leaf_query_team(member="anton", since="2026-05-19T00:00:00Z")` → returns structured timeline JSON with events from past 24h.
9. Anton leaves workspace «TestRoom» → Settings → Workspace → switch to other workspace → «TestRoom» row → [Wipe cache data] button → type-name confirmation → cascade delete. Sidebar removes «TestRoom». Disk: `~/Library/Application Support/Leaf/keystore/workspaces/<wid>/` no longer exists.
10. Both Macs sleep 90min → wake → Realtime channel still active (no reconnect storm in console logs) via in-place `access_token` rotation.

**Negative paths:**
1. `defaults write tech.gundem.leaf tier free; defaults read tech.gundem.leaf tier` → `free`. Re-launch Leaf. Team tab shows TeamFeedFreePreview (mockup) + Upgrade CTA. Sidebar empty workspace switcher shows «Upgrade to add workspaces». [Create workspace] button → disabled + UpgradeModal on click. Send DM disabled. Invite acceptance link → AcceptInviteSheet replaces [Join] with [Upgrade to accept] → UpgradeModal.
2. Force Mac B offline (Wi-Fi off) → Anton sends Task → APNs queued. Mac B Wi-Fi on → APNs delivers within Apple TTL. Click [Mark Done] → network still flaky → optimistic local UPDATE + `pending_mark_done = 1` → retry tick succeeds when network stable.
3. Dim Notifications setting «Auto-detected — Decision» OFF in Settings → Notifications. Anton commits and detector fires «decision» event → APNs Edge Function reads Dima's `notification_prefs.decision.enabled = false` → push skipped (Mac B sees no banner). Mac B feed STILL receives the event (broadcast/mirror path — notification prefs only affect APNs).
4. Cursor: `?leaf_query_team(member="ambiguous_name")` where 2 members have same display_name → error «Ambiguous member name — use pubkey hex».

---

## 9. Contract amendments

S8 produces 2 amendments to Track 5 contract per §18 living-doc process:

### 9.1 §10.3 — APNs payload shape — ADD `category` field

> **Amendment 2026-05-19 (S8 spec):** §10.3 APNs payload shape extended with `aps.category` field. Reason: UC-T5-3 «reply inline» + UC-T5-4 «click Mark done» require UNNotificationCategory + UNNotificationAction wiring; categories on standard alert push (per OQ-T5-4 resolution in S4) require `aps.category` field. Same amendment updates `aps.thread-id` format from `<workspace_id>` to `<workspace_id>:<kind>` to give separate Notification Center stacks per direct-message kind. Living-doc process per §18.

### 9.2 §15.1 — Tier values

> **Amendment 2026-05-19 (S8 spec):** §15.1 normalizes Tier value strings to `free` / `team` (matching contract §15.2 «Free tier» / «Team tier» display naming). S8 design draft used `pro` — corrected before impl. UserDefaults key remains `tier` per §15.1. Living-doc process per §18.

---

## 10. Open limitations (documented for post-S8)

### 10.1 Tier-gate honor-system bypass (sec C3)

MVP tier-gate is client-side only (UserDefaults check). User with shell access can run `defaults write tech.gundem.leaf tier team` to bypass restrictions. Acceptable for MVP per контракт §15.3 «post-launch Stripe» — actual entitlement enforcement is post-launch. Server-side JWT `tier` claim scaffolding lands в S8 so post-launch Stripe integration is just an Auth Hook function update + RLS policy enable.

### 10.2 Onboarding tier-fork

S8 default `tier = "team"` for MVP → all users land Onboarding Pro path, no first-workspace paradox. When Stripe lands and default flips to `tier = "free"`, Onboarding needs tier-fork: Free user shown «Join existing workspace (invite link required)» + Upgrade CTA, skipping workspace creation. Track 6 carry-over.

### 10.3 Full account wipe

S8 hard-wipe is **cache wipe** — preserves team_keys + team_members audit metadata. Full «Remove account» (forensic wipe including keys + members) is Track 6 feature with separate destructive UX + Supabase auth.users deletion via service_role.

### 10.4 Per-recipient share rules

NOT in S5; NOT in S8. Coming Track 6 / v1.1.

### 10.5 Settings tab-style navigation

WindowSettingsView remains scroll-style (10 sections). macOS native System Settings tab-style is a different SwiftUI pattern; out of S8 scope.

### 10.6 APNs token rotation on signOut (sec unchecked)

When user signs out and signs in fresh, new auth.uid() but same X25519 pubkey → potentially orphan apns_tokens rows under old `pubkey`. Carry-over.

### 10.7 TierGateReader KVO cross-process

UserDefaults change observation via @Observable: cross-process update may not propagate (Agent process changes UserDefaults from background → MenuBarApp doesn't see). Track 6 carry-over (likely needs explicit notification post + observe).

### 10.8 leaf_query_team aggregation

MVP returns raw structured timeline of events. Track 6 enhancement: optional summary stats per source (counts + top repos / top issues / etc.) for AI consumption convenience. Per UC-T5-2 contract text, MVP timeline format is sufficient.

---

## 11. Privacy invariants (re-affirmed)

All Track 5 + Track 1 invariants stand. S8-specific:

- **APNs payload** still title-only (no body excerpt) per контракт §6 + §10.3.
- **`waitlist` table** stores email only — no pubkey association, no per-user metrics. (Email is voluntary marketing capture, не linked to existing leaf account.)
- **`notification_prefs` server mirror** — pubkey ↔ pref_kind ↔ enabled boolean. No content leaked.
- **`leaf_query_team` MCP output** — uses TeamEventPayloadBuilder allowlisted keys only (same allowlist as broadcast path); sentinel fence (test §6.1) regression-tests for ai_* / body_kind / preview leaks.
- **`tier` JWT claim** — always `"team"` MVP; no per-user payment data exposed.
- **EncryptedRow struct** (Phase H) — compile-time enforcement that decryptor closure cannot see sender_pubkey / kind / replyTo before C2/C3 trust gates apply.
- **Hard-wipe audit invariant** — team_keys + team_members rows preserved through cache wipe (matches existing WorkspaceService.softDelete:168 contract).
- **dm.markDone retry queue** — `pending_mark_done` flag stored locally only, no Supabase mirror (single-device state for retry coordination).

---

## 12. References

- Contract — `docs/superpowers/specs/2026-05-13-track-5-collaboration-contract.md`
- S4 spec (APNs / DM lifecycle) — `docs/superpowers/specs/2026-05-14-track-5-S4-direct-messages.md`
- S5 spec (ShareSource / ShareRulesStore / retention pruner pattern) — `docs/superpowers/specs/2026-05-15-track-5-S5-auto-share.md`
- S7 spec (Realtime substrate / Reader-Service split / FeedItem.grouped) — `docs/superpowers/specs/2026-05-16-track-5-S7-team-ui.md`
- WorkspaceService audit invariant — `Packages/LeafCore/Sources/LeafCore/Team/WorkspaceService.swift:168`
- Phoenix access_token frame — `Packages/LeafCore/Sources/LeafCore/Network/RealtimePhoenixMessage.swift:103-110`
- Reviewer transcripts — adversarial security / architectural / cross-spec (3 parallel agents, 2026-05-19)
