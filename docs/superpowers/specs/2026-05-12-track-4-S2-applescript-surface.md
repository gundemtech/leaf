# Track-4 S2 — AppleScript Surface

**Date:** 2026-05-12
**Status:** Draft (brainstorm-approved via Track-4 design contract; implementation plan in same session per user direction "иду в зал — спек и план оба сразу")
**Owner:** Dmitrii
**Branch (off):** `feature/track-4-S1-architecture-catch-up` (tip `d334d38`, Track-4 S1 landed locally — awaiting collective merge after S4 per Track-4 contract §"Phase decomposition order")
**Branch (new):** `feature/track-4-S2-applescript-surface`
**Contract:** `docs/superpowers/specs/2026-05-11-track-4-local-os-sweep-design.md` § "S2 — AppleScript surface"

## Goal

Реализовать AppleScript-based per-app introspection поверх ~12 macOS apps (Xcode / JetBrains family / Music / Spotify / Apple Notes / Reminders / Calendar.app / Mail / Zoom / Safari / Chrome / Arc), сохраняя substrate-only дисциплину — никаких новых SQLCipher tables, никаких schema migrations, никаких external API providers. Substrate vкл. одного orchestrator-collector (`AppleScriptCollector`), общего `AppleScriptBridge` actor wrapper над NSAppleScript, общего permission-state cache (`AppleScriptPermissionStore`) с 24h denial backoff, и factory-injected `AppleScriptAdapterRegistry` (per-app adapters в LeafCorePrivate moat).

S2 — **вторая sub-phase из четырёх в Track 4** (после S1 — Architecture Catch-up landed; перед S3 — System Observers + Intensity; и S4 — Substrate Integration). Каждая шипится в свою feature branch; collective merge после S4 + Track-4 acceptance gate per Track-4 contract §"Phase decomposition order".

## Context

Track-4 S1 landed 4 OS-boundary collectors (`CalendarCollector` / `FocusModeCollector` / `SystemStateCollector` / `SpacesCollector`) — все S1 коллекторы структурно ГЕТЕРОГЕННЫ (2 async-polling + 2 @MainActor observer-only; 2 TCC-gated + 2 без permission). Per-collector декомпозиция была правильным выбором для S1.

S2 adapters структурно ГОМОГЕННЫ — все 12 apps:

- @MainActor NSAppleScript invocation (Apple API constraint)
- Identical timeout race pattern (default 1.0s, Zoom override 3.0s)
- Identical TCC error code mapping (-1743 → denied / -600 → app not running / -1712 → timeout)
- Identical permission cache shape (per (source-bundleID, target-bundleID) pair, 24h denial backoff)
- Identical polling lifecycle (one timer per adapter, varying interval, same start/stop semantics)

Variation per app — **только** в `(script body + response parser + boundary value type + state machine + event_kinds set)`. Это естественная adapter pattern: orchestrator-collector содержит общий lifecycle / scheduling / TCC-error-mapping / permission-cache, per-app adapters инжектятся через protocol + `#if LEAF_PROD` factory (mirror Linear/GitHub/Slack `Prod*Provider` pattern уже работающий в репо).

**Downstream consequences if S2 ships:**

- **Activity tab depth:** Track-5 UI-A может surface "what user is doing in Music / Xcode / Notes" beyond just app name. Currently `ActiveAppCollector` ships только app bundle ID + AX window title (200 chars).
- **Derived Insights:** "user works longest sessions in IntelliJ on weekdays" / "Spotify playing while coding correlates with focus blocks". S2 substrate captures the data; S4 / Track-5 surface it.
- **Cross-app correlations:** Track-1 D3 detectors могут consume "user switched from Xcode → Slack → back to Xcode" patterns (Track-4 S2 substrate makes it possible; detection ships separately).

**No S3 dependency on S2.** S2 + S3 — orthogonal substrate work. S3 CGEventTap subscribes to `SystemStateCollector.isLocked` / `.isSleeping` (S1 shipped this already); S2 не used by S3 internals.

## Scope

### In scope

1. **`AppleScriptBridge` (LeafCore)** — @MainActor actor wrapper над NSAppleScript:
   - `func executeScript(_ script: String, timeoutSec: Double) async -> AppleScriptResult`
   - `enum AppleScriptResult { case success(NSAppleEventDescriptor), denied, appNotRunning, timeout, scriptError(code: Int, message: String), unavailable }`
   - Timeout via `Task.detached` race: AS execution off MainActor (NSAppleScript-safe under MainActor.assumeIsolated since AS is main-thread-bound) + cancellation race с `Task.sleep(nanoseconds:)`. First completion wins.
   - Error mapping: `-1743` → `.denied` (TCC), `-600` → `.appNotRunning`, `-1712` → `.timeout` (от макси), `-2741` / другие parse errors → `.scriptError`. Catch-all → `.unavailable`.

2. **`AppleScriptPermissionStore` (LeafCore)** — @MainActor actor, UserDefaults-backed:
   - `enum AppleScriptPermissionState { case notRequested, granted, denied(Int64), appNotInstalled, unavailable }`
   - `func cachedState(for bundleID: String) -> AppleScriptPermissionState`
   - `func record(_ state: AppleScriptPermissionState, for bundleID: String, nowMs: Int64)`
   - `func shouldProbe(for bundleID: String, nowMs: Int64) -> Bool` — true if `notRequested`, OR `denied(t)` AND `nowMs - t > 24*3600*1000`, OR `granted` (always re-poll when granted).
   - Keys: `"appleScript.permission.state.<bundleID>"` + `"appleScript.permission.deniedAtMs.<bundleID>"`. State persisted across agent restart.

3. **`AppleScriptAdapter` protocol (LeafCore)** — narrow protocol каждый per-app adapter conform'ит:
   ```swift
   public protocol AppleScriptAdapter: Sendable {
       var targetBundleIDs: Set<String> { get }    // 1+ (JetBrains family ships 11)
       var eventKinds: Set<ShareEventTypeKey> { get }  // for registry verification
       var pollIntervalSec: TimeInterval { get }   // per-adapter
       var timeoutSec: Double { get }              // per-adapter, default 1.0
       var probeScript: String { get }             // minimal script для probe TCC dialog
       func tickScript(for bundleID: String) -> String   // real script for emit
       func parse(_ descriptor: NSAppleEventDescriptor, for bundleID: String) -> AdapterObservation?
       mutating func observe(_ observation: AdapterObservation, nowMs: Int64) -> [RawEvent]
   }
   ```
   `AdapterObservation` — protocol-bounded enum или typed associated type carrying one of 12 per-adapter `<App>Observation` boundary types. Public LeafCore ships protocol + `NoOpAppleScriptAdapter` (returns empty events). Real impls в LeafCorePrivate.

4. **`AppleScriptAdapterRegistry` protocol (LeafCore)** — `var adapters: [any AppleScriptAdapter] { get }`. Public ships `EmptyAppleScriptAdapterRegistry()` returning `[]`. LeafCorePrivate ships `ProdAppleScriptAdapterRegistry()` returning все 12 adapters. Factory wired в Agent.main() через `#if LEAF_PROD`.

5. **`AppleScriptCollector` (LeafAgent)** — orchestrator:
   - Holds: `bridge: AppleScriptBridge`, `permissionStore: AppleScriptPermissionStore`, `localAppsStore: LocalAppsStore`, `registry: any AppleScriptAdapterRegistry`, `writer: EventWriter`.
   - `start()`: spawn one Task per adapter (each polling at adapter's `pollIntervalSec`); store handles в slot array; iteration order independent.
   - `stop()`: cancel all Tasks, await termination.
   - Per-tick (`tickAdapter(_:)` private):
     - Iterate `adapter.targetBundleIDs` — for each bundleID:
       - Check `localAppsStore.isEnabled(bundleID)` — skip if OFF.
       - Check `permissionStore.shouldProbe(bundleID, nowMs)` — skip if denied <24h ago.
       - Check `appInstalled(bundleID)` via NSWorkspace lookup — record `.appNotInstalled` if missing, skip tick.
       - Execute adapter's `tickScript(for: bundleID)` via bridge.
       - Switch on result:
         - `.success(d)` → `permissionStore.record(.granted, bundleID)` → `adapter.parse(d, for: bundleID)` → `adapter.observe(obs, nowMs)` returns `[RawEvent]` → enqueue all via writer.
         - `.denied` → `permissionStore.record(.denied(nowMs), bundleID)` (no event emit).
         - `.appNotRunning` → silent no-op (no state update — user just didn't open app today).
         - `.timeout` → log warn, no state update (transient).
         - `.scriptError(c, m)` → log warn с code, no state update.
         - `.unavailable` → `permissionStore.record(.unavailable, bundleID)`.
   - Probe script flow: first-time toggle ON → first tick calls `tickScript` directly (NOT separate probe). macOS shows TCC dialog under `tech.gundem.leaf.agent`. User responds → state recorded → subsequent ticks proceed normally.

6. **12 per-app boundary types (LeafCore `OS/` directory)** — each a narrow `public struct: Sendable, Hashable`:

   | Boundary type | Fields | Forbidden adjacent fields |
   |---|---|---|
   | `XcodeObservation` | `activeDocPath: String?`, `projectName: String?`, `schemeName: String?`, `buildState: BuildState` | source / content / text of document |
   | `JetBrainsObservation` | `ideBundleID: String`, `projectName: String?`, `activeDocPath: String?` | source / content / text of document |
   | `MusicTrackObservation` | `trackName: String?`, `artistName: String?`, `playerState: PlayerState` | (none — track + artist allowed surface) |
   | `SpotifyTrackObservation` | `trackName: String?`, `artistName: String?`, `playerState: PlayerState` | (none) |
   | `NotesObservation` | `activeNoteTitle: String?` | body / plaintext / bodyHTML of note |
   | `RemindersCompletionObservation` | `listName: String?`, `completedCountDelta: Int` | body / notes / name of reminder (reminder titles ARE forbidden — only list name allowed) |
   | `CalendarAppViewObservation` | `viewMode: ViewMode`, `visibleDateRangeDays: Int` | summary / description / attendees / location / title of event |
   | `MailObservation` | `activeMailboxName: String?` | body / content / subject / sender / recipient / from / to |
   | `ZoomObservation` | `meetingState: ZoomMeetingState`, `ownMeetingTopic: String?` | participants / attendees / meeting password |
   | `SafariObservation` | `tabs: [BrowserTab]`, `activeWindowID: String?` | source / text / history / cookies / localStorage |
   | `ChromeObservation` | mirror Safari | mirror Safari |
   | `ArcObservation` | mirror Safari | mirror Safari |

   `BrowserTab { title: String, url: String }` shared across Safari / Chrome / Arc.

7. **12 per-app state machines (LeafCore `OS/` directory)** — each `mutating func observe(_:, nowMs:) -> [RawEvent]` (returns 0..N events; Xcode и Zoom могут emit 2 distinct event_kinds в одном tick).

8. **13 new ShareEventTypeKey cases:**
   - `xcodeActiveDocChanged` — `"xcode_active_doc_changed"`
   - `xcodeBuildStateChanged` — `"xcode_build_state_changed"`
   - `jetbrainsActiveDocChanged` — `"jetbrains_active_doc_changed"`
   - `musicTrackChanged` — `"music_track_changed"`
   - `spotifyTrackChanged` — `"spotify_track_changed"`
   - `notesActiveTitleChanged` — `"notes_active_title_changed"`
   - `reminderCompleted` — `"reminder_completed"`
   - `calendarAppViewChanged` — `"calendar_app_view_changed"`
   - `mailActiveMailboxChanged` — `"mail_active_mailbox_changed"`
   - `zoomMeetingStateChanged` — `"zoom_meeting_state_changed"`
   - `zoomMeetingNameObserved` — `"zoom_meeting_name_observed"`
   - `safariTabsChanged` — `"safari_tabs_changed"`
   - `chromeTabsChanged` — `"chrome_tabs_changed"`
   - `arcTabsChanged` — `"arc_tabs_changed"`

   Actual count: **14 cases** (Xcode 2 + Zoom 2 + остальные 1 each = 14). All `defaultEnabled: false` per ADR-020. Registry size 125 (S1 ship) → **139 (+14)**.

9. **`LocalAppsStore` (LeafCore)** — @MainActor `ObservableObject`:
   - `@Published var enabledMap: [String: Bool]`
   - `@Published var subFieldOptedIn: [String: Set<String>]` — keyed by bundleID, set of sub-field names ("mailboxName" / "ownMeetingTopic" / etc).
   - `func setEnabled(_ bundleID: String, _ enabled: Bool)`
   - `func isEnabled(_ bundleID: String) -> Bool`
   - `func setSubFieldOptedIn(_ bundleID: String, field: String, optedIn: Bool)`
   - `func isSubFieldOptedIn(_ bundleID: String, field: String) -> Bool`
   - UserDefaults-backed; keys `"localApps.enabled.<bundleID>"` + `"localApps.subField.<bundleID>.<field>"`.

10. **`LocalAppsSettingsSection` (Leaf Settings UI)** — new SwiftUI view rendering per-adapter rows:
    - `LeafSection "Local Apps"` outer
    - `LeafCard.subdued` header + caption ("Reads what you're working on through Apple's automation API. Each app asks permission separately.")
    - Per-adapter `LeafCard.raised` row:
      - `LeafListRow` — app icon (NSWorkspace.shared.icon(forFile:) если installed; else placeholder glyph) + app name + permission state badge + LeafToggle (binding to `LocalAppsStore.isEnabled`) + LeafIconButton (info → expand explainer drawer).
      - Drawer: per-adapter explainer (1-2 sentences); Mail/Zoom sub-toggle ("Also capture mailbox names" / "Also capture meeting topic"); if denied → LeafBanner.warning "Permission denied — click to open System Settings → Automation"; if appNotInstalled → LeafBanner.info "<App> not installed".

11. **`AgentLifetime` — +1 slot** (`appleScriptCollector: AppleScriptCollector?`).

12. **`AgentThresholds` — +2 fields:**
    - `appleScriptDefaultTimeoutSec: Double = 1.0`
    - `appleScriptPerAppTimeoutOverridesJson: String = "{\"us.zoom.xos\":3.0}"` — JSON dict of bundleID → timeout, parsed in moat.

13. **`LeafAgent/Info.plist` extension** — +1 key:
    - `NSAppleEventsUsageDescription = "Leaf observes which app and file you're working on through Apple's automation API. Never reads document content, email body, or message text."`

14. **`Agent.main()`** — construct `AppleScriptCollector` after S1 collectors:
    - Build bridge + permissionStore + localAppsStore (both shared with main app via UserDefaults).
    - Build registry via `#if LEAF_PROD { ProdAppleScriptAdapterRegistry() } #else { EmptyAppleScriptAdapterRegistry() }`.
    - Construct collector. Start via `Task { await appleScriptCollector.start() }`. Shutdown chain prepended `Task { await appleScriptCollector.stop() }` BEFORE S1 collectors.

15. **`PermissionsService` extension** — NOT per-app booleans (would bloat). Single helper accessor `localAppsPermissionStore: AppleScriptPermissionStore` + reactive view of permission state per adapter row.

### Out of scope (later phases or won't-list)

- **CGEventTap / intensity counters / clipboard / audio / mic / display / VPN / WiFi / Bluetooth / FSEvents widening** — Track-4 S3.
- **FTS body-kind dispatcher additions / iconography в Activity tab / share_event_types runtime persistence table** — Track-4 S4.
- **AS dictionary stability per macOS version automated regression tests** — manual smoke pre-release only; per-version compat suite deferred to operational concern.
- **AppleScript content reads** — body / source / content / cookies / participants — ADR-010 won't-list, never. Boundary value types + source-grep tests enforce compile-time.
- **Onboarding extension** — AS permissions are on-demand only per Track-4 contract; no new Onboarding step.
- **Detection / linking consumption** — Track-1 D3 detectors don't currently use AS events; consuming the new signal is left для future phase. S2 ships capture only.
- **Apps WITHOUT AppleScript dictionaries** (Slack desktop / Cursor / VS Code / Notion / Linear desktop / Discord / Telegram / WhatsApp / Figma / ChatGPT / Claude desktop / Firefox) — AX window title capture already shipped Phase 4.10.B.
- **Layer D native plugins** (Figma plugin / VSCode extension / Chrome extension) — completely separate track, V1.5+.

## Architecture

### Skeleton

```
LeafCore (public substrate)
├── OS/AppleScriptBridge.swift          @MainActor actor; NSAppleScript wrapper + timeout race + error mapping
├── OS/AppleScriptResult.swift          enum result type
├── OS/AppleScriptPermissionStore.swift @MainActor actor; UserDefaults-backed; 24h denial cache
├── OS/AppleScriptAdapter.swift         public protocol; targetBundleIDs/eventKinds/poll/scripts/parse/observe
├── OS/AppleScriptAdapterRegistry.swift public protocol; LeafCore ships Empty impl
├── OS/<App>Observation.swift × 12      narrow boundary types per app
├── OS/<App>StateMachine.swift × 12     pure transition detectors
├── Share/LocalAppsStore.swift          @MainActor ObservableObject; UserDefaults-backed enabled+sub-field maps
└── Share/ShareEventTypeRegistry.swift  +14 new ShareEventTypeKey cases, all default OFF

LeafAgent (public)
└── Collectors/AppleScriptCollector.swift   Orchestrator; one Task per adapter; permission cache & dispatch

LeafCorePrivate (gitignored moat)
├── Prod/Collectors/Apple/Prod<App>Adapter.swift × 12  Script bodies + response parsers + state machine integration
└── Prod/Collectors/Apple/ProdAppleScriptAdapterRegistry.swift  Lists 12 adapters

Leaf (main app)
├── Views/Window/Settings/LocalAppsSettingsSection.swift  Per-app row UI
└── Models/PermissionsService.swift  +localAppsStore accessor, +per-app probe trigger
```

### Permission state machine

```
notRequested ──first tick when Local Apps toggle ON──► [bridge.execute(tickScript)]
                                                      ├─ success ─► granted
                                                      ├─ -1743 ──► denied(nowMs)
                                                      ├─ -600 ───► (stays notRequested if first; else stays granted)
                                                      ├─ timeout/scriptError ─► (no state change)
                                                      └─ catch ──► unavailable

granted ──next poll tick──► [bridge.execute(tickScript)]
                            ├─ success ─► granted (continues)
                            ├─ -1743 ──► denied(nowMs) (user revoked in System Settings)
                            └─ ...

denied(t) ──next poll tick──► shouldProbe(nowMs)? (true if nowMs - t > 24h)
            ├─ no ──► skip tick
            └─ yes ─► [bridge.execute(tickScript)] (re-probe)
                      ├─ success ─► granted (user manually granted in System Settings)
                      └─ -1743 ──► denied(nowMs) (reset 24h timer)

appNotInstalled ──user opens Local Apps Settings──► (UI shows "App not installed" badge)
                  ──appInstalled becomes true (e.g. user installed Xcode)──► notRequested

unavailable ──manual reset via "Retry" button──► notRequested
```

### Per-adapter tick dispatch

```
AppleScriptCollector.tickAdapter(_ adapter: any AppleScriptAdapter):
    for bundleID in adapter.targetBundleIDs:
        guard localAppsStore.isEnabled(bundleID) else { continue }
        guard permissionStore.shouldProbe(bundleID, nowMs) else { continue }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            permissionStore.record(.appNotInstalled, bundleID, nowMs)
            continue
        }
        let script = adapter.tickScript(for: bundleID)
        let result = await bridge.executeScript(script, timeoutSec: adapter.timeoutSec)
        switch result {
            case .success(let d):
                permissionStore.record(.granted, bundleID, nowMs)
                if let obs = adapter.parse(d, for: bundleID) {
                    let events = adapter.observe(obs, nowMs)
                    for ev in events {
                        await writer.enqueue(ev)
                    }
                }
            case .denied:
                permissionStore.record(.denied(nowMs), bundleID, nowMs)
            case .appNotRunning:
                continue
            case .timeout:
                logger.warning("AS timeout for \(bundleID)")
            case .scriptError(let c, _):
                logger.warning("AS script error \(c) for \(bundleID)")
            case .unavailable:
                permissionStore.record(.unavailable, bundleID, nowMs)
        }
```

### Event payload shapes

All S2 events use `SignalType.attention` (per architecture.md §"Типы сигналов" — "Attention — что делал — app + duration + intensity"). Payload — minimum-information:

- `xcode_active_doc_changed` — `{event_kind, project: String?, scheme: String?, doc_path: String?}` (doc_path full на устройстве; Share Controls truncates на share time)
- `xcode_build_state_changed` — `{event_kind, build_state}` where build_state ∈ {"idle", "running", "succeeded", "failed"}
- `jetbrains_active_doc_changed` — `{event_kind, ide_bundle_id, project: String?, doc_path: String?}`
- `music_track_changed` — `{event_kind, track: String?, artist: String?, player_state}` where player_state ∈ {"playing", "paused", "stopped"}
- `spotify_track_changed` — same shape
- `notes_active_title_changed` — `{event_kind, note_title: String?}` (NO body field)
- `reminder_completed` — `{event_kind, list_name: String?, completed_count_delta: Int}` (NO reminder title/body)
- `calendar_app_view_changed` — `{event_kind, view_mode, visible_date_range_days}`
- `mail_active_mailbox_changed` — `{event_kind, mailbox_name: String?}` — emitted only если `localAppsStore.isSubFieldOptedIn("com.apple.mail", "mailboxName") == true`
- `zoom_meeting_state_changed` — `{event_kind, meeting_state}` where meeting_state ∈ {"in_meeting", "not_in_meeting", "waiting_room", "screen_sharing"}
- `zoom_meeting_name_observed` — `{event_kind, meeting_topic: String?}` — emitted only если `localAppsStore.isSubFieldOptedIn("us.zoom.xos", "ownMeetingTopic") == true`
- `safari_tabs_changed` / `chrome_tabs_changed` / `arc_tabs_changed` — `{event_kind, tabs: [{title, url}], active_window_id: String?}` — emit only on tab-set diff (state machine collapses no-op polls)

**No new `EventPayloadKeys` constants** — `event_kind` уже canonical. Per-app payload keys (`project` / `track` / `tabs` / etc) добавляются в `Schema.EventPayloadKeys` enum (mirror Track-3 D3 pattern). ~22 new EventPayloadKeys constants total.

### File touches

| File | Change |
|---|---|
| `Packages/LeafCore/Sources/LeafCore/OS/AppleScriptBridge.swift` | NEW — @MainActor actor wrapper |
| `Packages/LeafCore/Sources/LeafCore/OS/AppleScriptResult.swift` | NEW — enum |
| `Packages/LeafCore/Sources/LeafCore/OS/AppleScriptPermissionStore.swift` | NEW — @MainActor actor, UserDefaults-backed |
| `Packages/LeafCore/Sources/LeafCore/OS/AppleScriptAdapter.swift` | NEW — public protocol + `AdapterObservation` enum |
| `Packages/LeafCore/Sources/LeafCore/OS/AppleScriptAdapterRegistry.swift` | NEW — public protocol + EmptyAppleScriptAdapterRegistry |
| `Packages/LeafCore/Sources/LeafCore/OS/XcodeObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/JetBrainsObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/MusicTrackObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/SpotifyTrackObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/NotesObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/RemindersCompletionObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/CalendarAppViewObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/MailObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/ZoomObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/SafariObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/ChromeObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/ArcObservation.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/BrowserTab.swift` | NEW — shared `BrowserTab { title, url }` |
| `Packages/LeafCore/Sources/LeafCore/OS/XcodeStateMachine.swift` | NEW |
| ... ×11 more state machines (one per adapter) | NEW |
| `Packages/LeafCore/Sources/LeafCore/Share/LocalAppsStore.swift` | NEW — @MainActor ObservableObject |
| `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` | EDIT — +14 cases + 14 defaults (all default OFF), registry size 125 → 139 |
| `Packages/LeafCore/Sources/LeafCore/Schema.swift` | EDIT — +22 new `EventPayloadKeys` constants |
| `Packages/LeafCore/Sources/LeafCore/Agent/AgentThresholds.swift` | EDIT — +2 fields (appleScriptDefaultTimeoutSec, appleScriptPerAppTimeoutOverridesJson) |
| `LeafAgent/Collectors/AppleScriptCollector.swift` | NEW — orchestrator |
| `LeafAgent/Agent.swift` | EDIT — construct + start + stop AppleScriptCollector; AgentLifetime +1 slot |
| `LeafAgent/Info.plist` | EDIT — +NSAppleEventsUsageDescription |
| `Leaf/Models/PermissionsService.swift` | EDIT — +localAppsPermissionStore accessor |
| `Leaf/Views/Window/Settings/LocalAppsSettingsSection.swift` | NEW — per-adapter row UI |
| `Leaf/Views/Window/Settings/SettingsView.swift` (или равноценно — точка интеграции Settings tab) | EDIT — добавить LocalAppsSettingsSection между General и Privacy |
| `Packages/LeafCore/Tests/LeafCoreTests/AppleScriptBridgeTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/AppleScriptPermissionStoreTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/AppleScriptCollectorDispatchTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/LocalAppsStoreTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/<App>StateMachineTests.swift` × 12 | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/ShareEventTypeRegistryS2Tests.swift` | NEW — registry size 139 + 14 default OFF |
| `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` | EDIT — +14 walkbacks |
| `Packages/LeafCore/Tests/LeafCoreTests/S2AdapterSourceGrepTests.swift` | NEW — per-adapter forbidden field substring checks |
| `Packages/LeafCore/Tests/LeafCoreTests/AppleScriptAdapterRegistryTests.swift` | NEW — empty vs prod (mock) factory |
| `.claude/shared/current-state.md` | EDIT — closing note for S2 + Track-4 stack status |

LeafCorePrivate (moat) edits — gitignored:

| File | Change |
|---|---|
| `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Collectors/Apple/ProdXcodeAdapter.swift` | NEW |
| ... ×11 more `Prod<App>Adapter.swift` | NEW |
| `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Collectors/Apple/ProdAppleScriptAdapterRegistry.swift` | NEW — lists 12 adapters |
| `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Configs/AgentThresholdsProd.swift` | EDIT — Zoom timeout override |
| Per-adapter moat fixture tests | NEW — ~30-40 moat tests |

No schema migration. No new SQLCipher tables. No `leaf-relay` changes. No `Leaf.xcodeproj/project.pbxproj` edits (LeafAgent Info.plist landed в S1 already).

## Permissions UX

### TCC entry per binary

`NSAppleEventsUsageDescription` lives в `LeafAgent/Info.plist` only — LeafAgent (process `tech.gundem.leaf.agent`) — единственный binary, который вызывает NSAppleScript. Main app не делает AS calls — нет смысла дублировать TCC entries.

**Single prompt UX per (agent, target-bundleID) pair** — agent fires one TCC dialog under `tech.gundem.leaf.agent` per target bundle ID at first tick. User grants once per pair; persists across agent restart через macOS TCC.db. Better чем S1 dual-prompt (main app + agent), потому что main app не делает AS calls.

**JetBrains family adapter caveat** — family adapter has `targetBundleIDs: Set<String>` (11 IDE bundle IDs). TCC scopes per (source, target) pair → user receives a separate TCC prompt the first time each JetBrains variant is encountered (e.g., IntelliJ prompt on first IntelliJ poll; PyCharm prompt on first PyCharm poll). Acceptable per on-demand model — promptов нет до первого encountered usage.

### Settings → Local Apps screen

Layout (mirror Track-2 D3/D4 substrate):

```
LeafSection "Local Apps"
  ╭─ LeafCard.subdued (header) ────────────────────────╮
  │ Local Apps                                          │
  │ Reads what you're working on through Apple's        │
  │ automation API. Each app asks permission separately.│
  ╰────────────────────────────────────────────────────╯
  ╭─ LeafCard.raised (per adapter row × 12) ───────────╮
  │ [icon] Xcode              [Granted ✓] [Toggle] [ⓘ] │
  │   └── (drawer when ⓘ expanded)                     │
  │       Captures active document + project + scheme + │
  │       build state. Path is truncated to folder by   │
  │       default; full path shared only if you opt in. │
  ╰────────────────────────────────────────────────────╯
  ... (11 more rows: JetBrains / Music / Spotify / ...)
```

Permission badge mapping:
- `notRequested` → "Waiting" (gray)
- `granted` → "Granted ✓" (green)
- `denied(t)` → "Denied" (red) + LeafBanner.warning "Click to open System Settings → Automation"
- `appNotInstalled` → "Not installed" (gray, italic)
- `unavailable` → "Unavailable" (gray) + "Retry" button

Mail / Zoom rows ship secondary sub-toggle in drawer:
- Mail: "Also capture mailbox names" (default OFF, gates `mail_active_mailbox_changed` emission)
- Zoom: "Also capture meeting topic" (default OFF, gates `zoom_meeting_name_observed` emission)

Settings → Privacy section (`PrivacySettingsSection.swift`) — NOT extended. AS permission management lives only в Local Apps section.

### Onboarding flow

NOT extended per Track-4 contract. AS permissions are on-demand only. Onboarding shape остаётся `welcome → ax → fda → observers → team → done` (S1's six-step flow).

## Privacy walkbacks (mandatory)

Per Track-4 contract §"Privacy walkback" + ADR-010 §6:

1. **Per-adapter source-grep tests** (`S2AdapterSourceGrepTests.swift`) — generic runner iterates `(adapterSourceFile, forbiddenSubstrings)` pairs. Each adapter source file (LeafCorePrivate `Prod<App>Adapter.swift`) — comment-stripped — scanned for forbidden API/field substrings:
   - **Apple Notes:** `body of note`, `plaintext of note`, `body`, `plainTextContent`
   - **Reminders:** `body of reminder`, `notes of reminder`, `name of reminder`
   - **Calendar.app:** `summary of event`, `description of event`, `attendees`, `location of event`, `title of event`
   - **Mail:** `body`, `content`, `subject`, `sender`, `recipient`, `from`, `to`
   - **Zoom:** `participants`, `attendees`, `meeting password`
   - **Safari/Chrome/Arc:** `source of`, `text of`, `history`, `cookies`, `localStorage`
   - **Xcode/JetBrains:** `text of document`, `content of document`, `source of document`
   - **Music/Spotify:** none (track + artist allowed)

   Tests run under `#if LEAF_PROD` since adapter sources live в moat. Public substrate ships NoOp adapter — source-grep там checks NoOp doesn't accidentally introduce forbidden fields.

2. **`RelayBodyLeakageTests` extension — 14 new walkbacks** (one per event_kind). Each constructs adversarial `RawEvent` payload with PII marker (e.g., `"body": "SECRET-NOTE-BODY-MARKER-S2"` injected в Notes event payload) → writes via `writeEventsOffsetAndPresence` → asserts `presence_state.state_json` doesn't contain marker. Mirrors S1's 4 walkback extensions; total walkbacks count 34 (S1 ship) → **48 (+14)**.

3. **Boundary type compile-time guarantee** — каждый `<App>Observation` value type narrowly enumerates allowed fields. Adding `body: String?` к `NotesObservation` is intentionally a public-source diff that requires explicit code review (no accidental ingestion path).

4. **Sub-field opt-in gates** — `mail_active_mailbox_changed` and `zoom_meeting_name_observed` events ONLY emit if `LocalAppsStore.isSubFieldOptedIn` returns true. State machine для Mail / Zoom takes optional sub-field flag as input + returns empty event list если flag false (even if observation changed). Tested via `MailStateMachineTests.subFieldOptInGatesEmission` + `ZoomStateMachineTests.subFieldOptInGatesTopicEmission`.

## Test plan

TDD sequential per CLAUDE.md "Одна phase = одна сессия" → Stage 5 ("write failing test → run → see fail → implement → run → see pass → commit; after every step all tests still pass").

### Test count delta

| Layer | Tests |
|---|---|
| Baseline (Track-4 S1 ship) | 1715 |
| AppleScriptBridge (timeout + error mapping + success path + empty script + concurrent invocation safety) | +6 |
| AppleScriptPermissionStore (24h denial cache + state transitions + UserDefaults round-trip + appNotInstalled lookup + unavailable reset) | +8 |
| AppleScriptCollector dispatch (skip-if-disabled + skip-if-denied-<24h + record-on-success + record-on-denied + appNotInstalled-handling + writer-enqueue-only-on-transition) | +6 |
| LocalAppsStore (UserDefaults round-trip + Observable updates + sub-field map) | +4 |
| State machines (Xcode 5 + JetBrains 4 + Music 4 + Spotify 4 + Notes 4 + Reminders 4 + Calendar.app 4 + Mail 5 + Zoom 5 + Safari 5 + Chrome 5 + Arc 5; Mail+Zoom +1 each for sub-field gate) | +54 |
| ShareEventTypeRegistryS2Tests (size 139 + 14 default OFF + enum case raw values + ShareEventTypeKey iteration consistency) | +4 |
| RelayBodyLeakageTests extension (14 new walkbacks) | +14 |
| S2AdapterSourceGrepTests (per-adapter forbidden field substring; 12 adapters) | +12 |
| AppleScriptAdapterRegistry (empty vs mock prod + protocol conformance) | +3 |
| **Target** | **~1826 (1715 + 111 new ± 10 tolerance)** |

### Build verification

After every implementation step:
1. `swift test --package-path Packages/LeafCore` — all green
2. `just check-tokens` + `just check-tokens-self-test` — both PASS
3. `just build-all` — 5/5 xcodebuild schemes (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP) green

## Acceptance criteria

- **AC1:** All 1715 baseline SPM tests pass; **~1826 total** after S2 ship (1715 + 111 new ± 10 tolerance).
- **AC2:** 5/5 xcodebuild schemes green (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP).
- **AC3:** `just check-tokens` PASS + `just check-tokens-self-test` PASS.
- **AC4:** `ShareEventTypeKey.allCases.count == 139` (125 baseline + 14 new); `ShareEventTypeDefaults.all.count == 139`; every new key `defaultEnabled == false`.
- **AC5:** Manual smoke on Author's Mac:
  - Cold install → Settings → Local Apps section visible, 12 adapter rows, all toggles OFF default.
  - Toggle Music ON → TCC prompt fires under `tech.gundem.leaf.agent`. Click Allow → permission badge "Granted ✓". Play track in Music → DB row `music_track_changed` within 30s. Pause → emit. Switch track → emit.
  - Toggle Xcode ON → TCC prompt → grant → switch active doc → DB row `xcode_active_doc_changed` within 60s. Trigger build → `xcode_build_state_changed` (running → succeeded/failed).
  - Toggle Apple Notes ON → TCC prompt → grant → switch active note → `notes_active_title_changed`. Verify payload contains only `note_title`; NO `body` / `plainTextContent` field.
  - Toggle Mail ON → secondary "Capture mailbox names" sub-toggle visible, default OFF. With sub-toggle OFF → switch mailbox → NO `mail_active_mailbox_changed` event emitted (sub-field gate). Enable sub-toggle → switch mailbox again → event emits with `mailbox_name` field. Disable sub-toggle → stops emission.
  - Toggle Reminders ON → complete a reminder → `reminder_completed`. Verify payload never contains reminder title or body — only `list_name` + `completed_count_delta`.
  - Toggle Safari ON → TCC prompt → grant → open/close tabs → `safari_tabs_changed` emits ONLY on tab-set diff (run for 5 minutes idle → verify 0 emits while no tab changes; switch tabs / open new → emit).
  - Toggle a row → click Deny на TCC dialog → permission badge → "Denied" + LeafBanner.warning visible. Verify no events emitted for 24h. Then revoke + immediately re-toggle ON: NO re-prompt within 24h window.
  - "Open System Settings" deep-link from denied row opens System Settings → Privacy → Automation correctly.
  - Cold restart agent: permission state persists across restart (UserDefaults).
- **AC6:** `RelayBodyLeakageTests` extension (14 new walkbacks) passes. Adversarial payloads with PII markers (e.g., "SECRET-NOTE-BODY-MARKER", "SECRET-MAILBOX-CONTENT-MARKER") do NOT leak in `presence_state.state_json`.
- **AC7:** `S2AdapterSourceGrepTests` passes — все 12 forbidden field substring lists clean across adapter sources (LEAF_PROD build).
- **AC8:** Permission cache 24h denial logic verified manually — toggle adapter ON, deny TCC, immediately toggle OFF/ON again → no re-prompt; wait `denied(t) + 24h + 1min` → toggle ON or wait for next poll tick → re-probe fires.
- **AC9:** `otool -P build/Debug/LeafAgent | grep NSAppleEventsUsageDescription` returns the usage string.
- **AC10:** Sub-field opt-in gates verified — Mail mailbox name event AND Zoom meeting topic event NOT emitted when sub-toggle OFF, even when adapter toggle ON.

## Risks

- **R1 (medium):** AS dictionary stability per macOS version. JetBrains / Zoom / Arc dictionaries особенно volatile. **Mitigation** — adapter `parse` returns nil gracefully on schema mismatch; orchestrator skips emission (no crash); `AppleScriptPermissionState.unavailable` set for that adapter; UI shows "Limited compatibility" badge. Per-version compat test suite — defer to manual smoke matrix pre-release.
- **R2 (medium):** Browser tab capture volume. 30s poll × active workday × multi-tab user = potentially 100-500 emits/day per browser per user. Storage cost: ~50KB/day per browser. **Mitigation** — emit only on tab-set diff (state machine collapses no-op polls). If real-world surfaces issue → increase coalesce window в S3 polish OR move to event-driven WebKit notifications в S4.
- **R3 (low):** TCC prompt fatigue. User toggles 5 apps → 5 TCC dialogs. **Mitigation** — UX copy explicit ("Each app asks permission separately"); LocalAppsSettingsSection row stays interactive while waiting for TCC; multiple prompts can be granted без re-opening Settings.
- **R4 (low):** AS-blocking malware-detection software (CrowdStrike, SentinelOne) может block NSAppleScript executions. Symptom: timeout returns silently, no events emitted. **Mitigation** — `unavailable` state + UI badge "Blocked by security policy"; manual remediation guide.
- **R5 (low):** macOS Sequoia+ changed AS prompt UX (per-app vs blanket). **Mitigation** — adapter probe scripts designed to be minimal (one read of harmless property); same prompt model works through macOS 14-15-26.
- **R6 (very low):** `appleScriptPerAppTimeoutOverridesJson` parse failure (malformed JSON in moat config) → fallback to default 1.0s for all. Acceptable graceful degrade.

## Dependencies

- ✅ Track-4 S1 ship (`feature/track-4-S1-architecture-catch-up` tip `d334d38`) — provides baseline 1715 SPM tests; `LeafAgent/Info.plist` embedded; PermissionsService extended pattern proven; LocalAppsStore-style ObservableObject precedent.
- ✅ Track-2 D4 — Settings substrate (LeafSection / LeafCard / LeafListRow / LeafToggle / LeafBanner / LeafIconButton) tokens + token-discipline guard.
- ✅ Track-3 stack (D1 + linear-reconciliation + D2 + D3 + D4) — no surface conflict с S2.
- ❌ Track-4 S3 (CGEventTap + system observers) — does NOT block S2; S2 не used by S3 internals.
- ❌ Track-5 UI-A (shell redesign) — useful для Activity tab AS-event iconography в S4, не blocking S2.
- No `leaf-relay` changes.
- No external API providers.

## Open questions

- **OQ-S2-1 (Zoom huddle vs full meeting):** Zoom AS dict exposes `is meeting` boolean. Doesn't distinguish full meeting vs huddle. **Decision:** boolean is enough — both surface as `in_meeting` state. Refine if real-world need surfaces.
- **OQ-S2-2 (Calendar.app vs S1 CalendarCollector overlap):** S1 `CalendarCollector` reads EventKit (in_meeting boolean). S2 `Calendar.app` adapter reads view mode (Day/Week/Month). Two different signals — no overlap. Both ship.
- **OQ-S2-3 (Arc AS dict completeness):** Arc has historical AS dict issues — may emit empty results consistently. **Decision:** include adapter, mark `unavailable` if probe fails consistently across 5 ticks. Don't block S2 ship на Arc completeness.
- **OQ-S2-4 (per-adapter sub-field opt-ins beyond Mail/Zoom):** Should Notes also have "Capture note titles" sub-opt-in? Reminders "Capture list names"? **Decision:** S2 doesn't go beyond Mail (mailbox = third-party PII) and Zoom (meeting topic = often client PII). Notes titles + Reminders list names are user-private-but-not-third-party-PII; default ON at adapter level when Local Apps toggle ON. User can disable Notes/Reminders entirely if uncomfortable.
- **OQ-S2-5 (browser private/incognito mode):** AS query against Safari private window — should adapter filter out private tabs? Browsers expose `properties` but inconsistent across versions. **Decision:** rely on browser native behavior — AS dict for Safari excludes private tabs by default; Chrome incognito tabs are AS-invisible. No explicit filter in adapter. Documented в privacy walkback test.
- **OQ-S2-6 (event_kind for tabs_changed — single shape or per-browser):** Three event_kinds vs one generic `browser_tabs_changed` with `browser` payload key. **Decision:** per-browser. Source attribution в event_kind упрощает Share Controls per-browser toggling + per-browser FTS body_kind dispatching в future S4.
- **OQ-S2-7 (path L4/L5 granularity for tests):** Boundary type carries full path; Share Controls truncates. **Decision:** S2 tests verify capture full path; share-time truncation тестируется отдельно в Share Controls test suite (already exists).
- **OQ-S2-8 (AS-bridge concurrent invocation safety):** NSAppleScript is main-thread-bound. AppleScriptBridge — @MainActor — serializes invocations. Если 12 adapters tick одновременно — серийный pipeline, max throughput limited by slowest script. **Decision:** acceptable — adapter ticks are independent; worst-case 12 × 1.0s = 12s pipeline (rare; typical ticks <100ms). If surfaces issue → bridge можно сделать actor с private serial DispatchQueue вне MainActor.
- **OQ-S2-9 (probe-vs-tick script separation):** Spec consolidates probe + tick into single `tickScript` invocation (first tick after toggle ON acts as probe). Alternative: separate `probeScript` (minimal — `tell app id 'X' to launch`) vs `tickScript` (real query). **Decision:** consolidated. Reasoning: separate probe adds complexity без UX benefit (TCC dialog fires same way; user sees same prompt copy). Minimal probe also can't fail-validate parser — better to surface parse errors immediately.

## Workflow per CLAUDE.md "Одна phase = одна сессия"

Eight stages. S2 spec covers Stages 1-3; S2 plan (same session per user direction) covers Stage 4. Stages 5-8 happen в next session.

1. ✅ Discovery (Stage 1) — done: contract read, S1 spec + plan form mirror'нуты, Explore subagent substrate snapshot returned
2. ✅ Brainstorm (Stage 2) — done: orchestrator-vs-per-collector architectural choice resolved (A — single orchestrator + per-app adapters)
3. ✅ Spec write (Stage 3) — **this document**
4. ⏭ Plan (Stage 4) — **same session continuation**; file `docs/superpowers/plans/2026-05-12-track-4-S2-applescript-surface.md`
5. ⏭ Implementation (Stage 5) — TDD sequential per plan, **separate session**
6. ⏭ Independent review (Stage 6) — `superpowers:code-reviewer` subagent или general-purpose subagent
7. ⏭ Verification (Stage 7) — `superpowers:verification-before-completion`
8. ⏭ Ship (Stage 8) — final commit `docs(shared): Phase Track-4 S2 landed — current-state update`. **NO push, NO merge** — Track-4 stack waits collective merge after S4 + Track-4 acceptance gate per Track-4 contract §"Phase decomposition order".

## Post-S2 path

S2 lands as a substrate-only sub-phase. After ship:

1. **Track-4 S3 work starts в separate session** — CGEventTap intensity counter + system observers (audio / mic / display / VPN / WiFi / Bluetooth / clipboard / FSEvents widening). Off `feature/track-4-S3-system-observers`, baselined on S2 ship tip.
2. **No Track-4 acceptance gate yet** — gate fires after S4 per contract §"Acceptance criteria (per sub-phase)" matrix. S2 individual smoke validates S2 alone (per §"Acceptance criteria → S2").
3. **No whitepaper sync** — Track-4 contract §"Phase decomposition order" states whitepaper sync deferred until post-S4 collective merge.
4. **Carry-forward to S3:** `AppleScriptPermissionStore` shape доказан → similar `SystemObserverPermissionStore` для CGEventTap accessibility / TCC state. S3 reuses LocalAppsStore-style ObservableObject pattern для master toggles (CGEventTap / WiFi / Clipboard).
