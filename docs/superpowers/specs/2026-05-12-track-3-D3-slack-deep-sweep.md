# Phase Track-3 D3 — Slack Deep Sweep

**Date:** 2026-05-12
**Branch:** `feature/track-3-D3-slack-deep-sweep` (off `feature/track-3-D2-github-deep-sweep` tip `7e6b881`, D2 + comma-fix hotfix)
**Stack position:** Track 3 third sub-phase. Stack: `main` → D1 (Linear deep sweep) → linear-reconciliation → D2 (GitHub deep sweep) → **D3 (this)** → D4 (cross-cutting). Collective merge after Track 3 acceptance gate.
**Contract:** `docs/superpowers/specs/2026-05-11-track-3-providers-deep-sweep-design.md` §"D3 — Slack matrix".
**Baseline:** 1466 SPM tests (post-D2 + hotfix), 5/5 xcodebuild schemes green, `just check-tokens` PASS, M001–M016, 28 SQLCipher tables, ShareEventTypeRegistry 97 entries.

---

## 1. Goals

Expand Slack coverage **8 → 27 event_kinds** (+19 net-new across warm 13 + cold 6), introduce **second OAuth scope-bump UX ceremony** in the stack (largest scope bump per contract — 9 new scopes), unify all Slack event_kinds under `slack_*` canonical prefix discipline (retroactive normalization of 2 pre-existing exceptions via M017), reuse D1/D2 substrate (`provider_snapshots` M015, atomic write helper, warm/cold scheduler patterns, scope-service architecture, DispatchCoverageTests fence) verbatim, mirror D2's privacy-regression discipline (RelayBodyLeakageTests sentinel walkbacks for every new body-bearing event_kind plus all dropped-text candidates).

**Non-goals:**
- Track-3 D4 (cross-cutting: FTS dispatcher unification across providers, ShareControls UI pagination for 116-entry registry, scope-status UI per-provider generalization) — separate sub-phase
- Whitepaper sync — deferred until full Track 3 ship per design spec §13
- Live runtime smoke on signed release — separate workstream
- Slack canvas/bookmark body content — ADR-010 §6 explicitly forbids; D3 captures title + lastEditedAt only
- Reminder text, pinned-message body, scheduled-message body — ADR-010 §6 forbids; dropped at provider boundary
- presence_state composite extension — keep relay budget tight; D3 expands captured surface, not broadcast surface

---

## 2. Architecture decisions

### 2.1 Naming — `slack_*` canonical prefix discipline (decision: **mirror D2**)

All Slack event_kinds (existing 8 + 19 new D3) live under canonical `slack_*` prefix forever. Two existing event_kinds lack the prefix and get renamed by M017:
- `message_authored_aggregate` → `slack_message_authored_aggregate`
- `huddle_state_change` → `slack_huddle_state_change`

The remaining 6 baseline kinds (`slack_thread_reply_aggregate`, `slack_status_change`, `slack_presence_state`, `slack_dnd_state`, `slack_mention_received_aggregate`, `slack_file_uploaded_aggregate`) already have the prefix and are no-op for M017.

**M017_NormalizeSlackEventKinds.swift** mirrors M016 byte-for-byte (2-entry `renameMap`, idempotent per-row UPDATE keyed on old name → re-run finds zero rows).

### 2.2 `SlackEventKindKey` typed enum (decision: **mirror `GitHubEventKindKey`**)

Public Swift enum `SlackEventKindKey: String, CaseIterable, Sendable, Hashable` in `Packages/LeafCore/Sources/LeafCore/Integrations/Slack/SlackEventKinds.swift`. **27 cases** = 8 existing + 19 new D3. Subsets:

- `legacyRenamed: Set<SlackEventKindKey>` = exactly the 2 cases M017 renames (`slackMessageAuthored`, `slackHuddleStateChange`). DispatchCoverageTests asserts this set ↔ M017.renameMap targets 1:1.
- `bodyBearing: Set<SlackEventKindKey>` = 4 cases that ship a body field for FTS indexing:
  - `slackCanvasCreated`, `slackCanvasEdited` (canvas title; ADR-010 §6 amendment allows title + lastEditedAt)
  - `slackBookmarkAdded`, `slackBookmarkRemoved` (user-set bookmark title + URL; same ADR-010 §6 reasoning — user-named resource, not message body)

Single source of truth for ShareEventTypeRegistry mirror, M017 rename map, FTS body-kind dispatch, ShareEventTypeDefaults table, DispatchCoverageTests.

### 2.3 `Schema.BodyKinds` additions (+2 constants)

In `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift`:
- `public static let slackCanvasTitle = "slack_canvas_title"`
- `public static let slackBookmarkTitle = "slack_bookmark_title"`

`EventsFullTextStore.topLevelBodyKind(forEventKind:)` extended with 4 new switch arms (canvas created/edited → `slackCanvasTitle`; bookmark added/removed → `slackBookmarkTitle`).

### 2.4 Scope management — `SlackScopesService` + `SlackScopesChecking` + `SlackScopesReader` (decision: **mirror D2 verbatim**)

New files:
- `Packages/LeafCore/Sources/LeafCore/Integrations/Slack/SlackScopesChecking.swift` — protocol `Sendable` with single async method `has(_ scope: String) async -> Bool`. Mirror `GitHubScopesChecking`.
- `Packages/LeafCore/Sources/LeafCore/Integrations/Slack/SlackScopesService.swift` — public actor mirroring `GitHubScopesService`. Two init paths (`init(grantedOverride:)` for tests + `init(database:)` for production lazy-load). Conforms to `SlackScopesChecking` via empty extension. Static `parseScopeString(_:)` splits on commas AND whitespace (mirror GitHub post-hotfix shape — Slack's `oauth.v2.access` response returns `authed_user.scope` as comma-separated; same parsing applies).
- `Leaf/Integrations/Slack/SlackScopesReader.swift` — `@MainActor @Observable` reader mirroring `GitHubScopesReader`. `ShipState` enum (`unknown / connected / connectedScopeOutdated(missing:) / notConfigured`). `DistributedNotificationCenter` subscriber on `tech.gundem.leaf.slack-integration-changed` (existing name from `SlackOAuthEndpoints.integrationChangedNotificationName`). `nonisolated(unsafe) var observer` deinit cleanup for Swift 6.

**Scope partitioning:**
- `requiredCore: Set<String>` = existing 9 (`users:read`, `users.profile:read`, `search:read`, `channels:history`, `groups:history`, `im:history`, `mpim:history`, `dnd:read`, `files:read`). Their absence = broken Slack baseline collector.
- `requiredOptional: Set<String>` = 9 new D3 (`reactions:read`, `pins:read`, `bookmarks:read`, `reminders:read`, `chat:read`, `stars:read`, `canvases:read`, `emoji:read`, `usergroups:read`). Banner surfaces "Unlock N new features" not "broken". Per-endpoint gating via `scopesService.has(<scope>)` → graceful skip with one-shot session log on missing.

`SlackOAuthService` gains `connect(scopes:)` overload accepting explicit scope array (default = `SlackScopesService.requested()`). `SlackOAuthEndpoints.userScopes` deprecated via `@available(*, deprecated, message: "Use SlackScopesService.requested()")`.

### 2.5 Re-auth UX (decision: **mirror D2 — proactive + per-launch session-dismiss**)

- **Home banner:** `LeafBanner.warning` proactive on launch when `slackScopes.state == .connectedScopeOutdated(...)`. Single CTA "Re-authorize Slack" + X-icon session dismiss.
- **Session-dismiss:** `UserDefaults` key `slack.reauth.bannerDismissedSessionID` storing UUID; compared against `AppSessionID.current` (per-launch UUID already wired by D2). Different → re-show after restart.
- **Connections "Slack Scopes" section:** `LeafSection` + `LeafCard.raised` + `LazyVGrid(.adaptive(minimum: 110))` badge matrix of all 18 scopes (9 core + 9 optional, each badge tinted green/red by granted-state) + per-scope explainer `LeafBanner.warning` for missing-core + subtle `LeafType.body.small` hint for missing-optional + `LeafButton` "Re-authorize Slack" CTA when anything missing. Renders on both `.connected` informational AND `.connectedScopeOutdated` actionable states. Localized DB read for `currentGranted` set (reader doesn't expose it; mirror D2 Connections pattern).
- **Sidebar `LeafDot(tone: .danger, size: .sm)` overlay:** D2 already wired this to Connections nav item conditioned on GitHubScopesReader state. Extend OR-condition: show dot when ANY of (GitHub scopes outdated, Slack scopes outdated). Same Atom A2 LeafDot, no new substrate.

### 2.6 Three-tier cadence — Hot / Warm / Cold

#### 2.6.1 Hot (existing, unchanged structure)

`SlackCollector` (`Packages/LeafCore/Sources/LeafCore/Collectors/SlackCollector.swift`) keeps its 5min polling loop and 8 baseline event_kinds. Only behavioral change: M017 renames the 2 pre-existing payload literals; inline emit-site strings updated to canonical `slack_*` form.

#### 2.6.2 Warm (15m, new) — `SlackWarmCollector` + `SlackWarmScheduler`

Mirror `GitHubWarmCollector` / `GitHubWarmScheduler` byte-for-byte:
- Single Task loop, await-on-cancel shutdown
- Half-interval startup delay (avoid colliding with hot 5m tick)
- Errors swallowed in runLoop (collector tick stays green)

**13 event_kinds across 7 endpoint groups:**

| Endpoint | Event_kinds | Required scope | Fan-out |
|---|---|---|---|
| `reactions.list` (own, paginated) | `slack_reaction_added` (1) | `reactions:read` | per-user |
| `pins.list` per channel diff | `slack_pin_added`, `slack_pin_removed` (2) | `pins:read` | per top-10 channel |
| `bookmarks.list` per channel diff | `slack_bookmark_added`, `slack_bookmark_removed` (2) | `bookmarks:read` | per top-10 channel |
| `reminders.list` | `slack_reminder_created`, `slack_reminder_completed` (2) | `reminders:read` | per-user |
| `chat.scheduledMessages.list` | `slack_message_scheduled`, `slack_message_sent_scheduled` (2) | `chat:read` | per-user |
| `stars.list` | `slack_item_saved`, `slack_item_unsaved` (2) | `stars:read` | per-user |
| `users.conversations` diff (channel membership) | `slack_channel_joined`, `slack_channel_left` (2) | existing `channels:read`/`groups:read`/`im:read`/`mpim:read` family already implied | per-user |

`users.conversations` is itself the per-channel fan-out source (see §2.7). Warm tick fetches it once → uses for membership diff AND drives all per-channel sub-fans.

#### 2.6.3 Cold (4am local, new) — `SlackColdCollector` + `SlackColdScheduler`

Mirror `GitHubColdCollector` / `GitHubColdScheduler` byte-for-byte:
- Calendar-based 4am anchor (`nonisolated nextLocal4am(after:)` + `shouldCatchUp(now:lastColdMs:)`)
- Initial catch-up gate via `lastColdMs > 24h` check (offset stored in `collector_offsets` keyed `slack:cold:<workspaceID>`)
- Injectable clock/calendar/loginProvider for tests

**6 event_kinds across 4 endpoint groups:**

| Endpoint | Event_kinds | Required scope | Fan-out |
|---|---|---|---|
| `conversations.canvases` per channel + free canvas list diff | `slack_canvas_created`, `slack_canvas_edited` (2) | `canvases:read` | per top-10 channel + per-user |
| `emoji.list` diff | `slack_custom_emoji_added` (1) | `emoji:read` | workspace-wide |
| `usergroups.list` + `usergroups.users.list` diff | `slack_usergroup_membership_changed` (1) | `usergroups:read` | workspace-wide |
| `conversations.info` per top-10 channel | `slack_channel_renamed`, `slack_channel_archived` (2) | existing | per top-10 channel |

### 2.7 Fan-out cap — top-10 active channels via `users.conversations`

Per-channel endpoints (pins, bookmarks, canvases, conversations.info) reuse a single ranked-list:

1. Warm tick fetches `users.conversations` once
2. Sort returned channels by `latest.ts` desc (most-recently-active first)
3. Take top-10
4. Write to `provider_snapshots(provider='slack', snapshot_kind='slack_member_channels_top10', snapshot_json=[...])`
5. Same warm tick + subsequent cold tick reuse this snapshot — no re-fetch per endpoint

**Rate-limit math:** 4 per-channel endpoints × 10 channels × 1 warm tick / 15min = 40 calls / 15min = 2.7 rpm. Slack Tier 2 (pins/bookmarks/conversations.info) caps at 20-50 rpm. Trivial headroom.

**Graceful degrade:** if `users.conversations` itself fails (rare), warm tick still emits membership-diff events from prior snapshot but skips per-channel sub-fans this tick; resumes on next tick when snapshot refreshes.

### 2.8 Provider snapshots — M015 reuse, **11 new `snapshot_kind` values**

D1 introduced `provider_snapshots(provider, snapshot_kind, snapshot_json, captured_at_ms)` composite PK WITHOUT ROWID. D3 reuses identically — no new migration:

- `slack_member_channels_top10` (warm — drives all per-channel fan-out)
- `slack_pins_per_channel` (warm — diff source per channel × pin)
- `slack_bookmarks_per_channel` (warm — diff source per channel × bookmark)
- `slack_reminders` (warm — id-set diff)
- `slack_scheduled_messages` (warm — id-set diff)
- `slack_stars` (warm — id-set diff)
- `slack_user_conversations` (warm — channel-id set for membership diff)
- `slack_canvases_per_channel` (cold — diff source per channel × canvas)
- `slack_emoji_list` (cold — name-set diff)
- `slack_usergroups` (cold — group_id × user_id matrix snapshot)
- `slack_channels_info` (cold — channel name + is_archived per channel)

**Bootstrap discipline (mirror D1/D2):** first tick writes snapshot, emits zero diff events; Day-2 emits real diffs. Snapshot row presence is the bootstrap gate.

### 2.9 ADR-010 §6 enforcement — payload composition discipline

For each new event_kind, payload `body` field is set ONLY when the kind is in `SlackEventKindKey.bodyBearing` (4 kinds). All other new kinds:
- `slack_pin_added` — captures channel + message_ts ref (NO message body)
- `slack_reminder_*` — captures reminder_id + due_ts + completion state (NO text)
- `slack_message_scheduled` — captures scheduled_for + channel (NO text)
- `slack_item_saved/_unsaved` — captures item_ref (channel + ts; NO content)
- `slack_reaction_added` — captures emoji-bucket + item_ref + count (NO text)
- `slack_channel_joined/_left` — captures channel_id + channel_name only
- `slack_custom_emoji_added` — captures emoji_name + URL ref (NO image bytes)
- `slack_usergroup_membership_changed` — captures group_id + added/removed user_ids (no profile data)
- `slack_channel_renamed` — captures channel_id + old_name + new_name (treated as metadata, not body — mirrors GitHub repo rename)
- `slack_channel_archived` — captures channel_id + is_archived bool

The text-dropping happens in moat (`ProdSlackAPIProvider`) at the HTTP-parse boundary — collector layer never sees the dropped fields. `RelayBodyLeakageTests` walkbacks (§2.12) prove this by injecting sentinel strings at the HTTP response level and asserting they never reach `presence_state.state_json`.

### 2.10 AgentLifetime / AgentThresholds / LeafApp wiring (mirror D2 verbatim)

**`AgentLifetime` +5 slots** (`Packages/LeafCore/Sources/LeafCore/Agent/Agent.swift` lifetime block):
- `nonisolated(unsafe) static var slackScopesService: SlackScopesService?`
- `nonisolated(unsafe) static var slackWarmCollector: SlackWarmCollector?`
- `nonisolated(unsafe) static var slackWarmScheduler: SlackWarmScheduler?`
- `nonisolated(unsafe) static var slackColdCollector: SlackColdCollector?`
- `nonisolated(unsafe) static var slackColdScheduler: SlackColdScheduler?`

**`AgentThresholds` +2 fields:**
- `public let slackWarmPollIntervalSec: TimeInterval` (default 900)
- `public let slackColdPollIntervalSec: TimeInterval` (default 86_400, not used by scheduler directly — 4am anchor instead; retained for symmetry per D2 precedent)

Mirrored in `weakDefaults` constant + moat `ProdConfigs.agent` carries prod overrides.

**`Agent.main()` gating** (mirror D2):
```swift
let slackScopesService: SlackScopesService? = !agentThresholds.slackOAuthClientID.isEmpty
    ? SlackScopesService(database: database)
    : nil
// warm/cold gated on (!slackOAuthClientID.isEmpty && slackScopesService != nil)
```

**Shutdown chain (reverse construct, in `AgentLifetime.shutdown()`):** cold scheduler → cold collector → warm scheduler → warm collector → existing slackCollector.

**`CollectorID` +2:** `slackWarmPolling = "slack_warm_polling"`, `slackColdPolling = "slack_cold_polling"`.

**`LeafApp.swift` wiring** (mirror D2 `githubScopes`):
- `@State private var slackScopes = SlackScopesReader(service: LeafApp.makeSlackScopesService())`
- Sibling private static `makeSlackScopesService() -> SlackScopesService?` mirroring `makeGitHubScopesService()` (default URL + ProdConfigs + FileKeyStore encryption; nil on failure → reader degrades to `.notConfigured`)
- `.environment(slackScopes)` propagated to Window content scene (skip MenuBarExtra per D2 precedent — those views don't render scope UX)

### 2.11 DispatchCoverageTests fence extension

Extend existing `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift` with 4 new tests mirroring the GitHub D2 quartet — iterates `SlackEventKindKey.allCases`:

1. `testEverySlackEventKindKeyAppearsInShareEventTypeRegistry`
2. `testSlackLegacyRenamedMatchesM017RenameMap` (symmetric `M017NormalizeSlackEventKinds.renameMap` targets ↔ `SlackEventKindKey.legacyRenamed` rawValues)
3. `testEverySlackBodyBearingKindHasFTSDispatchEntry` (via existing `bodyKindForTesting(eventKind:)` test helper)
4. `testEverySlackEventKindKeyHasShareDefaultEntry`

Per D2 lesson: enum is canonical, dispatch sites must mirror. Test #3 will surface any body-bearing entry missing from FTS dispatch the moment it's added.

### 2.12 Privacy regression — `RelayBodyLeakageTests` walkbacks (+7)

`Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` extended with 7 new tests (sentinel-injection pattern mirroring existing 23):

**Body-bearing positive (2 — assert sentinel reaches FTS but NOT presence_state):**
- canvas title sentinel
- bookmark title sentinel

**Dropped-text negative (5 — assert sentinel never reaches presence_state nor FTS):**
- pin message-body sentinel (HTTP response carries message text, provider boundary must drop)
- reminder text sentinel
- scheduled-message text sentinel
- custom-emoji image URL sentinel (drop URL — we capture name only)
- usergroup user-list profile-data sentinel (drop profile names — we capture user_ids only)

Each test follows existing pattern: stub `ProdSlackAPIProvider` returns sentinel-bearing payload → run write path → `SELECT state_json FROM presence_state WHERE provider='slack'` → `XCTAssertFalse(stateJSON.contains(sentinel))`.

### 2.13 `ShareEventTypeRegistry` — +19 entries, all default OFF (per ADR-020)

Registry grows **97 → 116**. All 19 new entries appended as Swift identifiers (camelCase) with rawValue = canonical `slack_*` form. All 19 entries also added to `ShareEventTypeDefaults.all` with `defaultEnabled: false` (capture locally, share selectively; user opts in per ADR-020).

Existing 8 Slack entries: 2 (`slackMessageAuthored`, `slackHuddleStateChange`) have their rawValue strings updated to canonical form; Swift identifiers preserved for call-site stability. Affected callers within the codebase — none (the 2 strings only appear in collector emit, registry, ShareEventTypeDefaults, and tests; M017 handles persisted data).

### 2.14 `presence_state.state_json` Slack composite — NO extension (intentional)

D3 expands captured-event surface, not relay-visible presence. Slack `presence_state` row stays at 9 keys (`native_presence`, `dnd`, `status_emoji`, `status_expiration_ts`, `in_huddle`, `huddle_channel`, `last_activity_channel`, `mention_count_today`, `file_count_today`). Future Phase 5.4 broadcast track can extend if needed; D3 keeps relay budget tight.

`writeEventsOffsetAndPresence` Slack branch in `Database` swift code is untouched — same 9-key composite write site.

---

## 3. Test count target

Conservative estimate: **+150-200 SPM tests**. Baseline 1466 → expected 1620-1670. Breakdown approximation:

- `SlackEventKindKey` enum + M017 + DispatchCoverageTests + ShareEventTypeRegistry mirror: ~20
- `SlackScopesService` + `SlackScopesReader` + `connect(scopes:)` overload + `parseScopeString`: ~30
- `SlackWarmCollector` tests (13 event_kinds × happy / empty / bootstrap discipline): ~50
- `SlackColdCollector` tests (6 event_kinds × happy / empty / bootstrap + 4am anchor + catch-up gate): ~40
- `SlackWarmScheduler` + `SlackColdScheduler` (mirror Linear D1 / GitHub D2 scheduler tests): ~15
- Moat fixture tests (`ProdSlackAPIProvider` 13 new endpoints — happy + 401 + 429 + parse-error paths): ~30
- `RelayBodyLeakageTests` +7
- Privacy / edge cases (graceful-degrade-on-scope-missing, top-10 cap enforcement, sub-fan skip-on-snapshot-missing): ~10

---

## 4. Files touched (estimate)

**New source files (public, LeafCore):**
- `Integrations/Slack/SlackEventKinds.swift` (enum + subsets)
- `Integrations/Slack/SlackScopesChecking.swift` (protocol)
- `Integrations/Slack/SlackScopesService.swift` (actor)
- `Collectors/SlackWarmCollector.swift` (actor)
- `Collectors/SlackColdCollector.swift` (actor)
- `Agent/SlackWarmScheduler.swift` (actor)
- `Agent/SlackColdScheduler.swift` (actor)
- `DB/Migrations/M017_NormalizeSlackEventKinds.swift`

**New source files (app, Leaf):**
- `Integrations/Slack/SlackScopesReader.swift` (`@MainActor @Observable`)

**Modified (public substrate):**
- `Integrations/Slack/SlackCollector.swift` (2 emit-site string updates)
- `Integrations/Slack/SlackOAuthService.swift` (`connect(scopes:)` overload)
- `Integrations/Slack/SlackOAuthEndpoints.swift` (deprecate `userScopes`)
- `Share/ShareEventTypeRegistry.swift` (+19 cases + 2 rawValue renames + 19 defaults)
- `DB/Schema.swift` (+2 BodyKinds + 2 CollectorIDs)
- `DB/EventsFullTextStore.swift` (+4 switch arms in `topLevelBodyKind`)
- `Detection/DetectorPipeline.swift` (+4 mirror arms in body-kind dispatch)
- `DB/Database.swift` (`Migrator` registers M017)
- `Agent/Agent.swift` (+5 lifetime slots, gating expression, shutdown chain)
- `Agent/AgentThresholds.swift` (+2 fields, weakDefaults sync)

**New test files (LeafCoreTests):**
- `SlackEventKindsTests.swift`
- `SlackScopesServiceTests.swift`
- `SlackWarmCollectorTests.swift`
- `SlackColdCollectorTests.swift`
- `SlackWarmSchedulerTests.swift`
- `SlackColdSchedulerTests.swift`
- `M017NormalizeSlackEventKindsTests.swift`
- `SlackPinsPerChannelDiffTests.swift`
- `SlackBookmarksPerChannelDiffTests.swift`
- `SlackUserConversationsDiffTests.swift`
- `SlackCanvasesPerChannelDiffTests.swift`
- `SlackUsergroupsDiffTests.swift`
- `ShareEventTypeRegistryD3SlackTests.swift`

**Modified test files (LeafCoreTests):**
- `DispatchCoverageTests.swift` (+4 Slack tests)
- `RelayBodyLeakageTests.swift` (+7 Slack walkbacks)
- `ShareEventTypeRegistryTests.swift` (count assertion 97 → 116)
- Existing `SlackCollectorTests.swift` (2 expected-event_kind string updates for rename)

**App UI files (Leaf):**
- `LeafApp.swift` (`slackScopes` @State + makeSlackScopesService + .environment propagation)
- Connections settings view (add "Slack Scopes" section)
- Home view (extend banner condition for Slack scope state)
- Sidebar nav (extend dot OR-condition for Slack scope state)

**Moat (LeafCorePrivate, gitignored):**
- `Prod/Collectors/ProdSlackAPIProvider.swift` (+13 fetch methods + per-channel fan-out helpers + scope-gated graceful degrade)
- Moat fixture tests (`LeafCorePrivateTests/ProdSlackAPIProviderWarmExtensionsTests.swift`, etc.)

---

## 5. Migration plan (M017)

```swift
public enum M017NormalizeSlackEventKinds {
    public static let renameMap: [(old: String, new: String)] = [
        ("message_authored_aggregate", "slack_message_authored_aggregate"),
        ("huddle_state_change",        "slack_huddle_state_change")
    ]

    public static func runRename(in db: GRDB.Database) throws {
        for (old, new) in renameMap {
            try db.execute(sql: """
                UPDATE events
                SET payload_json = json_set(payload_json, '$.event_kind', ?)
                WHERE json_extract(payload_json, '$.event_kind') = ?
                """, arguments: [new, old])
        }
    }
}

public extension DatabaseMigrator {
    mutating func registerMigration017NormalizeSlackEventKinds() {
        registerMigration("017_normalize_slack_event_kinds") { db in
            try M017NormalizeSlackEventKinds.runRename(in: db)
        }
    }
}
```

Idempotent: re-runs find zero rows for already-renamed entries.

`Database.openForWrite` registers M017 after M016 in migrator setup site.

---

## 6. Acceptance criteria

1. SPM full suite green: baseline 1466 → target ~1620-1670 (zero failures, baseline-skipped count preserved)
2. 5/5 xcodebuild schemes green (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP)
3. `just check-tokens` PASS (no raw color/padding/cornerRadius regression in new UI)
4. `just check-tokens-self-test` PASS
5. DispatchCoverageTests fence — 4 new Slack assertions pass; new event_kind addition impossible without all 4 mirror sites updated
6. ShareEventTypeRegistry size assertion: 97 → 116; all 19 D3 entries `defaultEnabled: false`
7. 28 SQLCipher tables (M017 is data migration, not new table)
8. RelayBodyLeakageTests +7 walkbacks pass (sentinel never in `presence_state.state_json` for any new kind)
9. Manual smoke deferred to Track 3 collective acceptance gate (per contract §13): on real Slack workspace — pin message → next warm tick emits `slack_pin_added` row; revoke `pins:read` scope → reader transitions to `connectedScopeOutdated` → Home banner + Sidebar dot + Connections explainer; re-authorize → grants → banner clears + pins.list fetches resume; 4am cold tick → canvas/emoji/usergroups/channel-info diffs emit; etc.

---

## 7. Open questions (carry into acceptance gate / next session)

**OQ-D3-1:** Slack `users.conversations` response shape — does `latest.ts` field reliably populate for all channel types (public / private / DM / mpim)? Empty `latest` (channels with no messages) → exclude from top-10 ranking. Verify during Task 1 implementation via real-API smoke or schema doc.

**OQ-D3-2:** `conversations.canvases` API — confirm response shape returns canvas titles WITHOUT body content. Per ADR-010 §6 if body leaks in response, drop at HTTP-parse boundary (mirror BodyCap discipline).

**OQ-D3-3:** Slack scope-grant response format from `oauth.v2.access` — confirmed comma-separated (`authed_user.scope`). `SlackScopesService.parseScopeString` mirrors GitHub's hotfix pattern (split on comma OR whitespace) for forward-compat with potential future format changes.

**OQ-D3-4:** Workspace plan dependencies — `canvases:read` and `bookmarks:read` may require specific Slack workspace tier (Standard+ vs Free). Test on Free-tier workspace during acceptance gate; if denied → reader marks scope as informational-only; gated endpoint skipped silently with one-shot log.

**OQ-D3-5:** `usergroups.list` requires admin scope on some workspaces? Verify. If admin-only → graceful skip on non-admin workspace, banner does not surface as "missing" (mirror GitHub D2 audit_log graceful pattern).

**OQ-D3-6:** Contract AC stated "14 new event_kinds"; table sums to 19. Spec implements 19 (table is the truth); spec changelog notes the AC correction. User can override during spec review.

**OQ-D3-7:** Slack OAuth re-auth flow — Slack OAuth v2 supports incremental scope grant (adding scopes without re-auth from scratch). Implementation should issue full `connect(scopes: requested())` flow which user re-consents (mirrors GitHub Device Flow re-auth pattern). Slack returns updated `authed_user.scope` in response; `SlackScopesService.refresh()` reads it.

---

## 8. Risk

- **Re-auth fatigue (largest concern):** D2 + D3 = two consecutive re-auth ceremonies for users who already onboarded baseline alpha. Mitigation: clear copy per ceremony explaining what unlocks; low-pressure dismissible banner (not forced modal); per-launch session-dismiss respects user's "later" intent.
- **Slack rate-limit on per-channel fan-out:** worst-case 4 endpoints × 10 channels × 1 warm tick / 15min = 2.7 rpm. Slack Tier 2 caps 20-50 rpm. Trivial headroom. Cold tier `conversations.info` per top-10 channel daily = 10 calls / 24h. Trivial.
- **Top-10 cutoff bias:** workspaces with >10 active channels lose visibility into ranks 11+. Mitigation: snapshot refresh every warm tick — top-10 is dynamic, not pinned. If a quieter channel surges, it re-enters top-10 within 15min. Tracked as v1.1 candidate: configurable N (UserDefault).
- **Free-tier workspace scope denials** (`canvases:read`, `bookmarks:read`, `usergroups:read` may require Slack Standard/Pro tier): handled via per-endpoint graceful skip + reader surfaces as `requiredOptional` missing. No collector breakage.
- **Linear precedent — external provider schema drift:** Slack API field renames possible between API versions. Mitigation: per-endpoint try/catch graceful degrade; introspection sweep during acceptance gate (mirror Linear schema-reconciliation lesson).

---

## 9. Whitepaper sync

Deferred until full Track 3 ship per design spec §13. D3 implementation moat (per-channel fan-out logic, scope discovery patterns, snapshot diff algorithms, exact endpoint mappings, ProdSlackAPIProvider internals) NOT published; architectural framing on public-safe level ("Slack coverage expanded to ~27 event_kinds across hot/warm/cold tiers; OAuth scope-bump UX extended with second provider reauth ceremony; canvases captured as title-only metadata per Won't-list discipline") goes into `leaf-docs` after full Track 3 collective merge in separate session.

---

## 10. Stack discipline

- NOT merged into main upon completion — D3 stays on `feature/track-3-D3-slack-deep-sweep` branch
- Track 3 collective merge order: D1 → linear-reconciliation → D2 → **D3** → D4 → acceptance gate → all-in-one merge
- Tactical plan written separately to `docs/superpowers/plans/2026-05-12-track-3-D3-slack-deep-sweep.md` (gitignored)
- Per-task subagent-driven TDD with two-stage review (spec compliance + code quality) — mirror D2 workflow byte-for-byte

---

## 11. Changelog

- **2026-05-12** — initial spec write. AC count corrected from contract's "14" to "19" (table sum); flagged for user review.
