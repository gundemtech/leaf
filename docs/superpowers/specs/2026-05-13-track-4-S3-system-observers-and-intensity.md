# Track-4 S3 — System Observers + Intensity

**Date:** 2026-05-13
**Status:** Draft (brainstorm-approved via Track-4 design contract; OQ-S3-* closed inline with explicit decisions per user direction "иду в зал — решай сам")
**Owner:** Alex
**Branch (off):** `feature/track-4-S2-applescript-surface` (tip `8489a6e`, Track-4 S2 landed locally — awaiting collective merge after S4 per Track-4 contract §"Phase decomposition order")
**Branch (new):** `feature/track-4-S3-system-observers-and-intensity`
**Contract:** `docs/superpowers/specs/2026-05-11-track-4-local-os-sweep-design.md` § "S3 — System observers + intensity"

## Goal

Реализовать **OS-boundary intensity counter + system-state observers** — substrate-only surface которая capture'ит low-level signals про user activity (keystroke / mouse / app-switch counters per minute), audio routing, mic in-use, display reconfigurations, VPN state, WiFi state, clipboard event count, screenshot creation, downloads added, trash changes — без чтения content любой из них. **Counters and state booleans only.** Adds one new SQLCipher table (`intensity_aggregates`, M018) для minute-bucketed counter rollup; everything else lives в standard `events` table с additive payload kinds.

S3 — **третья sub-phase из четырёх в Track 4** (после S1 — Architecture Catch-up landed; после S2 — AppleScript Surface landed; перед S4 — Substrate Integration). Каждая шипится в свою feature branch; collective merge после S4 + Track-4 acceptance gate per Track-4 contract §"Phase decomposition order".

## Context

Track-4 contract §S3 enumerates 11 observer surfaces. Recon (этой session) против landed code base показал:

- **S1 collectors** дают S3 single load-bearing dependency: `SystemStateCollector.isLocked` / `.isSleeping` @MainActor read-only properties (`LeafAgent/Collectors/SystemStateCollector.swift:21-22`). S3 CGEventTap consumer must gate enable/disable по этим флагам — tap MUST NOT receive events while screen locked / system sleeping (won't-list, architecture.md §"Запрещено").
- **S2 LocalAppsStore pattern** (`Packages/LeafCore/Sources/LeafCore/Share/LocalAppsStore.swift:22-90`) даёт reusable cross-process UserDefaults suite `"tech.gundem.leaf"` + ObservableObject + NSLock-cached, thread-safe writer-from-any-actor pattern. S3 reuses этот pattern для **`SystemObserversStore`** (master per-observer toggles).
- **S2 AppleScriptPermissionStore** (`Packages/LeafCore/Sources/LeafCore/OS/AppleScriptPermissionStore.swift`) даёт permission-state-cache pattern (24h denial backoff). S3 reuses pattern для **`InputMonitoringPermissionStore`** (CGEventTap requires Input Monitoring TCC service, separate from AX).
- **S1 stopShutdown chain** (`LeafAgent/Agent.swift:609-624`) даёт ordering precedent: detectorScheduler → rotationFetchScheduler → Track-3 schedulers → S2 appleScriptCollector → S1 collectors → maintenance → fsEventsCollector → claudeCodeCollector → Linear/GitHub/Slack hot → writer. S3 inserts itself **between S2 appleScriptCollector.stop() и S1 spacesCollector.stop()**.
- **Migration substrate** ends at M017 (`Packages/LeafCore/Sources/LeafCore/DB/Migrations/M017_NormalizeSlackEventKinds.swift`). S3 ships **M018_IntensityAggregates**. Track-4 contract §S3 mentioned "M015" — but Track-3 D1/D2 + Track-1 D2 consumed M012-M017 between contract write date (2026-05-11) и now. Renumber to **M018**.
- **ShareEventTypeRegistry** size = 139 (S2 ship per current-state.md). S3 adds **+13** new keys (one per emitting event_kind), all default OFF per ADR-020. Target: registry size 152.
- **RelayBodyLeakageTests count** = 48 (S2 ship). S3 adds **+13 walkbacks** + dedicated **CGEventTapNoContentLeakageTests** suite. Target: 61 walkbacks (62 if `intensity_snapshot` gets two walkbacks for keystroke and mouse fields).

Track-4 contract §S3 lists three substrate constraints S3 honours:
1. **Counter-only intensity** — CGEventTap callback NEVER reads `.characters` / keycode / modifierFlags. Counter increments based ON event-type discriminator only.
2. **Boolean / enum-only side observers** — audio route → transport-type enum (no device names); mic in-use → boolean (no audio samples); display → boolean (no screen pixels); VPN → status enum; WiFi → state only (NO SSID — see OQ-S3-3 decision); clipboard → counter (NO content).
3. **Filename-only filesystem observers** — screenshot / download / trash watchers see file names, NEVER read file contents.

**Downstream consequences after S3 lands:**

- **Derived Insights Engine** gains "intensity per session" pulse — `intensity_aggregates` table aggregated by hour/session. Track-1 D3 `WhereStoppedDeriver` can correlate "user idle but micInUse → in voice call (not abandoned)".
- **CGEventTap stays inactive by default** — only starts when user explicitly opts in (Settings → Privacy → "Intensity monitoring" toggle ON), triggering Input Monitoring TCC. Other observers run at startup (no TCC, cheap), all event_kinds default OFF in ShareEventTypeRegistry (= captured locally, not in team broadcast).
- **No S4 dependency** — S3 ships substrate + per-event-kind registration; FTS body-kind dispatcher extension + iconography lives в S4 collective integration phase.

**No Bluetooth in S3.** Per Track-4 contract OQ-5 "BluetoothCollector value — likely low signal (most users connect AirPods 1x daily). Skip from S3? Recommendation: skip." → **Skipped from S3.** AirPods 1×/day signal-to-implementation-cost ratio is poor (IOBluetooth API verbose, device names = PII, requires Bluetooth.framework which has its own auth in macOS 12+). Revisit post-MVP if feedback shows demand.

## Scope

### In scope (10 surfaces, M018 migration, 1 store, 1 permission service extension, 1 Settings section extension)

1. **`CGEventTapCollector` (LeafAgent)** — central, complex.
   - Creates `kCGSessionEventTap` location, `.listenOnly` mode, mask = `.keyDown | .leftMouseDown | .rightMouseDown | .mouseMoved | .leftMouseDragged | .rightMouseDragged | .scrollWheel`.
   - Callback fires on internal RunLoop source (CFMachPort-based). Callback isolated such that the ONLY operation per event is `counter += 1` for either keystroke / mouse bucket — NEVER reads `.keycode` / `.characters` / `.modifierFlags` / `.mouseLocation`.
   - At each minute boundary (Task.sleep loop wakes at `floor(now / 60s) * 60s + 60s`), flushes accumulated counter → UPSERT row into `intensity_aggregates` table (PK = `minute_bucket_ms`) AND emits one `intensity_snapshot` RawEvent. Counter resets to zero.
   - **Foreground app snapshot** at flush time via `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`. "Primary app of minute" is the app at flush-tick; per-event tracking is out of scope (OQ-S3-1 decision).
   - **App-switch count** snapshotted at flush time from a sibling counter (`ActiveAppCollector` already fires `NSWorkspace.didActivateApplicationNotification` on main queue — CGEventTapCollector subscribes to the same notification on main, increments local `appSwitchCount` counter). One signal source, two consumers.
   - **System-state gating** — subscribes to `SystemStateCollector.isLocked` / `.isSleeping` via the @MainActor "ask-on-tick" pattern (each minute boundary checks the flags; if either is true, drops the bucket — write a row with `(keystrokes=0, mouse_moves=0, app_switches=app_switches_only_if_collected, foreground_app=nil)` and skip event emission). Tap itself stays installed but events are discarded in callback via `if isLocked || isSleeping { return nil }` early-return.
   - **Auto-restart on drop** — callback inspects `CGEventType`; if `.tapDisabledByTimeout` or `.tapDisabledByUserInput`, calls `CGEvent.tapEnable(tap:enable:true)` and continues. Log only — no metrics emitted (avoids noise).
   - **Permission gating** — must check `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == .granted` AND `AXIsProcessTrusted()` before installing tap. If either false → collector logs once, doesn't install tap; will re-check on next agent restart.
   - **Master toggle gating** — checks `SystemObserversStore.isEnabled("intensity")` at `start()`; if false → no-op startup (tap never installed). Master toggle change triggers `objectWillChange` → UI re-render only; agent doesn't react live to toggle changes (next agent restart picks up new state). Avoid mid-tap reconfiguration complexity in MVP.

2. **`AudioRouteCollector` (LeafAgent)** — CoreAudio default-output-device transport-type observer.
   - Uses `kAudioHardwarePropertyDefaultOutputDevice` listener to detect device changes.
   - On change: reads `kAudioDevicePropertyTransportType` (UInt32 — `kAudioDeviceTransportTypeBuiltIn`, `_Bluetooth`, `_USB`, `_DisplayPort`, `_AirPlay`, `_AVB`, `_FireWire`, `_HDMI`, `_Thunderbolt`, `_Aggregate`, `_Unknown`, etc).
   - Maps to narrow enum `AudioRouteCategory { case builtin, headphones, bluetooth, airplay, usb, displayPort, hdmi, unknown }` — no device names, no manufacturer info.
   - Emits `audio_route_changed` with `{audio_route: <category>}`. State-machine collapses no-ops (same category twice in a row = no emit).
   - No permission required.
   - @MainActor isolation — CoreAudio callbacks dispatch to a dedicated queue, hop to main for collector state mutation.

3. **`MicInUseCollector` (LeafAgent)** — CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` boolean listener on default input device.
   - Detects ANY process recording from system mic (Zoom / FaceTime / Slack huddle / Voice Memos / etc) — generic "user is in voice call" signal.
   - Listener-based (event-driven), no polling.
   - Emits `mic_in_use_entered` when prop transitions 0→1, `mic_in_use_exited` on 1→0.
   - Payload: `{state: "mic_in_use" | "mic_idle"}` (mirror S1 `system_locked` payload shape — `event_kind` is the discriminator, `state` is the human-readable value).
   - No permission required. NSMicrophoneUsageDescription **NOT NEEDED** — CoreAudio property listener doesn't capture audio, doesn't tap the mic, doesn't actuate the recording indicator (the green dot only fires when AVCaptureSession actually starts).

4. **`DisplayCollector` (LeafAgent)** — CoreGraphics `CGDisplayRegisterReconfigurationCallback`.
   - Callback fires on display add / remove / mode change.
   - Filters `CGDisplayChangeSummaryFlags` — emits ONLY on `.addFlag` (→ `display_connected`) or `.removeFlag` (→ `display_disconnected`). Ignores `.modeChangedFlag`, `.setMainFlag`, `.rotationFlag`, etc (too noisy, irrelevant signal).
   - Payload: `{state: "display_connected" | "display_disconnected"}`.
   - No permission required.

5. **`VPNCollector` (LeafAgent)** — `NEVPNManager.shared()` status KVO observer.
   - Observes `connection.status` property — emits `vpn_state_changed` on transition into stable state (`.connected` / `.disconnected` / `.invalid`). Ignores intermediate `.connecting` / `.disconnecting` / `.reasserting` (would flap).
   - Payload: `{state: "connected" | "disconnected"}`.
   - Limitation documented: NEVPNManager.shared() only observes the **first system-configured VPN profile** — third-party VPNs that ship as Network Extension (Cloudflare WARP, Tailscale, NordVPN tunnel-mode) don't surface here. Best-effort capture; document in OQ-S3-5.
   - No permission required.

6. **`WiFiCollector` (LeafAgent)** — `CWWiFiClient.shared().interface()` polling, state only.
   - **NO SSID capture.** Reads only `CWInterface.interfaceMode` (UInt32 — `.none` / `.station` / `.ibss` / `.hostAP`) and `CWInterface.powerOn() -> Bool`.
   - State machine emits `wifi_state_changed` only on transition `(powerOn=false ∨ mode=.none) ↔ (powerOn=true ∧ mode=.station)`. Reports as `{state: "connected" | "disconnected"}` — semantic, not raw mode-enum exposure.
   - Polling 60s (NSDistributedNotificationCenter posts WiFi changes but is unreliable; polling is the cheap, correct alternative).
   - **No Location permission needed** — `interfaceMode` + `powerOn()` do not require Location auth in macOS 13+. SSID would (`CWInterface.ssid()` returns nil without Location TCC); we explicitly don't read it.
   - **Decision rationale (OQ-S3-3 closed):** State-only avoids Location TCC prompt entirely; "user moved network" signal preserved via state transition. SSID PII concern eliminated. Future S4 polish can add sub-toggle "Capture WiFi SSID" with explicit Location prompt + opt-in; not in S3.

7. **`ClipboardCollector` (LeafAgent)** — NSPasteboard.changeCount delta polling.
   - Polls `NSPasteboard.general.changeCount` every 60s. Computes `delta = current - lastCount`.
   - On `delta > 0`, emits ONE event `clipboard_event_count` with `{count: <delta>}`. Resets `lastCount = current`.
   - **NEVER** reads `pasteboardItems`, `string(forType:)`, `propertyList`, or any content accessor.
   - No permission required.

8. **`LocalFilesWatcher` (LeafAgent)** — three FSEventStream-backed path watchers in one collector.
   - Path 1: User's screenshot directory (read once at start via `CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString)`; fallback to `~/Desktop`).
   - Path 2: `~/Downloads`.
   - Path 3: `~/.Trash`.
   - Each path's callback routes to a per-path matcher:
     - **ScreenshotMatcher** — locale-aware regex bank on filename: `^Screenshot\s+`, `^Screen\s+Shot\s+`, `^Снимок\s+экрана\s+`, `^Bildschirm`, `^Capture\s+d.écran`, `^Captura\s+de\s+pantalla`, `^スクリーンショット\s+`, `^스크린샷\s+`, `^Cattura\s+schermata`, `^Screen-?shot` (case-insensitive); extension whitelist `{.png, .heic, .jpg, .jpeg, .pdf}`. Match → emit `screenshot_taken` with `{filename: <basename>}`.
     - **DownloadsMatcher** — any new file in `~/Downloads` (FSEvent flag `.itemCreated` ∧ not a directory). Emit `download_added` with `{filename: <basename>}`. (Filename only; share-controls / future moat redaction can strip PII before share, but local capture keeps full filename for derived insights.)
     - **TrashMatcher** — coarse signal. Emit `trash_changed` with `{action: "added" | "emptied"}` based on FSEvent flag pattern (`.itemCreated` + multiple events in batch → "added"; significant removed-event burst with `.itemRemoved` → "emptied"). State machine collapses bursts within 2s coalesce window (mirror S1 `SpaceTransitionCoalescer`).
   - **FDA requirement** — `~/Desktop`, `~/Downloads`, `~/.Trash` are TCC-gated. LeafAgent inherits Full Disk Access grant from Onboarding (already shipped). If FDA denied → collector logs once, no-op startup; UI badge in Settings reflects denial.
   - One FSEventStream wraps all three paths (`FSEventStreamCreate` accepts a CFArray of paths).
   - Coalesce window: 2s per (matcher, kind, basename) — prevents Spotlight bursts producing duplicate emits.

9. **`SystemObserversStore` (LeafCore)** — @unchecked Sendable ObservableObject, UserDefaults-backed (shared suite `"tech.gundem.leaf"`), NSLock-cached.
   - Single level: `isEnabled(_ observer: String) -> Bool`, `setEnabled(_ observer: String, _ enabled: Bool)`.
   - Observer keys (10): `"intensity"` (default OFF — TCC + battery), `"clipboard"` (default ON), `"wifi"` (default ON), `"vpn"` (default ON), `"audio_route"` (default ON), `"mic_in_use"` (default ON), `"display"` (default ON), `"screenshot_watcher"` (default ON), `"downloads_watcher"` (default ON), `"trash_watcher"` (default ON).
   - Default semantics: collectors that need TCC (intensity = Input Monitoring) start OFF — user must opt in. Collectors that require no auth (audio/mic/display/VPN/clipboard/WiFi-state-only) and trivially-cheap-FSEvents (screenshot/downloads/trash, gated by FDA which already granted via Onboarding) start ON — they constitute Leaf's local memory substrate; user can disable per-observer in Settings → Privacy if uncomfortable.
   - UserDefaults keys: `"systemObservers.<observer>.enabled"`. Cache invariants mirror LocalAppsStore.

10. **`InputMonitoringPermissionStore` (LeafCore)** — @MainActor actor, UserDefaults-backed (shared suite `"tech.gundem.leaf"`).
    - State enum: `InputMonitoringPermissionState { case notRequested, granted, denied(Int64), unavailable }`.
    - `cachedState() -> InputMonitoringPermissionState`, `record(_ state: InputMonitoringPermissionState, nowMs: Int64)`, `shouldProbe(nowMs: Int64) -> Bool` — true if `notRequested`, OR `denied(t) && nowMs - t > 24*3600*1000`.
    - Keys: `"systemObservers.inputMonitoring.state"` (Int rawValue), `"systemObservers.inputMonitoring.deniedAtMs"`.
    - Probe at `start()`: `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` → maps `kIOHIDAccessTypeGranted`/`Denied`/`Unknown` to enum. First-time-probe also calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` (sync, surfaces TCC dialog under `tech.gundem.leaf.agent` first time).
    - **Note:** unlike S2's `AppleScriptPermissionStore` (per-bundleID keyed), this store is single-scoped (one Input Monitoring grant per binary, not per target).

11. **`PermissionsService` extension (main Leaf app)**
    - Add `inputMonitoringGranted: Bool` observed property.
    - Add `triggerInputMonitoringPrompt()` — calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` (synchronous; surfaces TCC dialog under `tech.gundem.leaf` first time; agent gets its own dialog under `tech.gundem.leaf.agent` on first poll tick).
    - Add `openInputMonitoringSettings()` — `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`.
    - Add `defaultInputMonitoringProbe()` static nonisolated — wraps `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted`.
    - Add `systemObserversStore: SystemObserversStore` injected let — same cross-process pattern as `localAppsStore`.

12. **`SystemObserversSettingsSection` (Leaf Settings UI)** — new SwiftUI view rendering 10 per-observer rows + Input Monitoring permission row.
    - `LeafSection "System observers"` outer
    - `LeafCard.subdued` header + caption ("Background observers capture context shifts — audio routing, displays, voice calls, downloads. Everything you see here is local-only by default; Share Controls (above) gate what reaches your team.")
    - Per-observer `LeafCard.raised` rows × 10:
      - `LeafListRow` — observer icon glyph + observer name + state badge ("On" / "Off" / "Permission needed" if intensity + denied) + `LeafToggle` (binding to `SystemObserversStore.isEnabled`).
    - Intensity row gets sub-section disclosure: "Permission status: Granted / Waiting / Denied" + `LeafButton` "Open System Settings" → deep-link to Input Monitoring pane.
    - Section integration: lives between existing **PrivacySettingsSection** and **LocalAppsSettingsSection** rows in Settings tab.

13. **`AgentLifetime` — +8 slots:**
    - `cgEventTapCollector: CGEventTapCollector?`
    - `audioRouteCollector: AudioRouteCollector?`
    - `micInUseCollector: MicInUseCollector?`
    - `displayCollector: DisplayCollector?`
    - `vpnCollector: VPNCollector?`
    - `wifiCollector: WiFiCollector?`
    - `clipboardCollector: ClipboardCollector?`
    - `localFilesWatcher: LocalFilesWatcher?`

14. **`AgentThresholds` — +5 fields:**
    - `cgEventTapMinuteBucketSec: TimeInterval = 60.0` (flush + emit cadence)
    - `clipboardPollIntervalSec: TimeInterval = 60.0`
    - `wifiPollIntervalSec: TimeInterval = 60.0`
    - `localFilesCoalesceWindowSec: TimeInterval = 2.0` (FSEvents burst dedup)
    - `screenshotDirectoryOverrideKey: String = ""` (override for testing — empty = read from `com.apple.screencapture` defaults; non-empty = absolute path)

15. **`Schema.EventPayloadKeys` — +5 new constants:**
    - `keystrokeCount = "keystroke_count"`
    - `mouseMoveCount = "mouse_move_count"`
    - `appSwitchCount = "app_switch_count"`
    - `foregroundApp = "foreground_app"`
    - `audioRoute = "audio_route"`
    - (`state` / `count` / `filename` / `action` already canonical from baseline.)

16. **13 new `ShareEventTypeKey` cases:**
    - `intensitySnapshot = "intensity_snapshot"`
    - `audioRouteChanged = "audio_route_changed"`
    - `micInUseEntered = "mic_in_use_entered"`
    - `micInUseExited = "mic_in_use_exited"`
    - `displayConnected = "display_connected"`
    - `displayDisconnected = "display_disconnected"`
    - `vpnStateChanged = "vpn_state_changed"`
    - `wifiStateChanged = "wifi_state_changed"`
    - `clipboardEventCount = "clipboard_event_count"`
    - `screenshotTaken = "screenshot_taken"`
    - `downloadAdded = "download_added"`
    - `trashChanged = "trash_changed"`
    - `intensityBucketDropped = "intensity_bucket_dropped"` (emitted when locked/sleeping causes a bucket to be discarded — useful for "user was AFK" inference). Default OFF.

    Registry size 139 → **152 (+13)**. All `defaultEnabled: false` per ADR-020.

17. **M018_IntensityAggregates migration + `IntensityAggregatesStore` (LeafCore DB)**
    - Table:
      ```sql
      CREATE TABLE intensity_aggregates (
        minute_bucket_ms INTEGER PRIMARY KEY,
        keystrokes INTEGER NOT NULL DEFAULT 0,
        mouse_moves INTEGER NOT NULL DEFAULT 0,
        app_switches INTEGER NOT NULL DEFAULT 0,
        foreground_app TEXT
      );
      CREATE INDEX idx_intensity_aggregates_bucket
        ON intensity_aggregates(minute_bucket_ms DESC);
      ```
    - `IntensityAggregatesStore` — DAO with `upsert(minuteBucketMs, keystrokes, mouseMoves, appSwitches, foregroundApp)`, `read(minuteRange: Range<Int64>)`, `purgeOlderThan(ms: Int64)` (retention).
    - **Retention** — `MaintenanceScheduler.runRetention()` already deletes from `events` table per `retentionDays`. Extend to also `DELETE FROM intensity_aggregates WHERE minute_bucket_ms < now - retentionDays * 86400 * 1000`.

18. **`LeafAgent/Info.plist` extension — +1 key:**
    - `NSInputMonitoringUsageDescription` — wait, this is NOT a real Info.plist key. `NSInputMonitoringUsageDescription` was added in macOS 10.15 but Apple's TCC reads it from the system service catalogue, not Info.plist. Actually — **Apple deprecated explicit usage strings for Input Monitoring after Mojave**; the system shows a generic prompt instead. **Verified via Apple's TCC docs (as of macOS 14):** no Info.plist key needed for `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`. The system prompt fires with a fixed copy. → **No Info.plist changes in S3.**

19. **`Agent.main()` construction** — wire 8 collectors + 1 store + 1 permission store after S2 `AppleScriptCollector`:
    - Build `SystemObserversStore` (cross-process suite).
    - Build `InputMonitoringPermissionStore`.
    - Build `cgEventTapCollector` (passes `systemStateCollector` reference, `systemObserversStore`, `inputMonitoringPermissionStore`, `writer`, `database` for intensity_aggregates DAO, `activeAppCollectorObserver: () -> Void` hook for app-switch counting).
    - Build `audioRouteCollector` / `micInUseCollector` / `displayCollector` / `vpnCollector` / `wifiCollector` / `clipboardCollector` / `localFilesWatcher` (each takes `writer`, `systemObserversStore`, relevant thresholds).
    - Start chain: `Task { await cgEventTapCollector.start() }` etc.
    - Shutdown chain prepended: cgEventTap → audioRoute → micInUse → display → VPN → WiFi → clipboard → localFiles BEFORE `appleScriptCollector.stop()`.

20. **`PermissionsService` test plan** — extend with `testInputMonitoringRefreshReadsClosure` (mirror existing test 1).

### Out of scope (later phases or won't-list)

- **Bluetooth collector** — Track-4 contract OQ-5 recommended skip; confirmed in S3 (low signal/cost ratio, PII device names, IOBluetooth API complexity).
- **CGEventTap content reads** — `.characters` / `.keycode` / `.modifierFlags` / `.mouseLocation` — ADR-010 won't-list, never. Boundary value type + source-grep tests enforce compile-time.
- **WiFi SSID capture** — explicit OUT in S3 (decision OQ-S3-3). Add sub-toggle in S4 polish if real demand emerges.
- **Mic audio sample capture** — never. CoreAudio property listener boolean only.
- **Screen pixel capture / OCR** — ADR-010 won't-list, never.
- **Third-party VPN observability** (Network Extension framework providers — Cloudflare WARP / Tailscale / etc) — best-effort skipped; document limitation in OQ-S3-5.
- **Bluetooth.framework (CoreBluetooth) integration** — different from IOBluetooth; reserved for v1.1+ if BLE peripheral context proves useful.
- **FTS body-kind dispatcher additions / iconography in Activity tab / share_event_types runtime persistence table** — Track-4 S4.
- **Onboarding extension** — intensity is on-demand opt-in via Settings only; no new Onboarding step.
- **Live reconfiguration on master-toggle change** — toggling intensity OFF→ON mid-session does NOT install the tap mid-run; agent restart needed. Avoid mid-tap reconfiguration complexity in MVP.
- **Detection / linking consumption** — Track-1 D3 detectors don't currently use intensity / mic state; consuming the new signal is left for a future phase. S3 ships capture only.

## Architecture

### Skeleton

```
LeafCore (public substrate)
├── OS/SystemObserversStore.swift          @unchecked Sendable ObservableObject; cross-process UserDefaults
├── OS/InputMonitoringPermissionStore.swift @MainActor actor; UserDefaults-backed; 24h denial cache
├── OS/AudioRouteCategory.swift            enum boundary type
├── OS/AudioRouteStateMachine.swift        no-op-collapse transitions
├── OS/MicInUseStateMachine.swift          0↔1 transitions
├── OS/DisplayStateMachine.swift           add/remove only
├── OS/VPNStateMachine.swift               stable-state transitions
├── OS/WiFiStateMachine.swift              connected ↔ disconnected
├── OS/ClipboardCounterStateMachine.swift  delta > 0 emission gate
├── OS/IntensityBucketAccumulator.swift    minute-boundary flush logic
├── OS/ScreenshotMatcher.swift             locale-aware filename regex bank
├── OS/DownloadsMatcher.swift              created-file detection
├── OS/TrashMatcher.swift                  added/emptied coalesce
├── DB/Migrations/M018_IntensityAggregates.swift
├── DB/IntensityAggregatesStore.swift      DAO for upsert / read / purge
└── Share/ShareEventTypeRegistry.swift     +13 new ShareEventTypeKey cases, all default OFF

LeafAgent (public)
├── Collectors/CGEventTapCollector.swift     Central — tap install + callback + minute flush + Input Monitoring + AX gating
├── Collectors/AudioRouteCollector.swift     CoreAudio default-output-device transport listener
├── Collectors/MicInUseCollector.swift       CoreAudio default-input-device kAudioDevicePropertyDeviceIsRunningSomewhere listener
├── Collectors/DisplayCollector.swift        CGDisplayRegisterReconfigurationCallback
├── Collectors/VPNCollector.swift            NEVPNManager.shared() KVO
├── Collectors/WiFiCollector.swift           CWWiFiClient.shared() polling
├── Collectors/ClipboardCollector.swift      NSPasteboard.changeCount delta polling
└── Collectors/LocalFilesWatcher.swift       Three-path FSEventStream wrapper + per-path matcher dispatch

Leaf (main app)
├── Views/Window/Settings/SystemObserversSettingsSection.swift   Per-observer toggle rows + Input Monitoring CTA
└── Models/PermissionsService.swift                              +inputMonitoringGranted + triggerInputMonitoringPrompt + openInputMonitoringSettings + systemObserversStore
```

### CGEventTap permission state machine

```
notRequested
   │
   ├── master toggle "intensity" OFF → no-op (tap not installed; stays notRequested)
   │
   └── master toggle "intensity" ON
          │
          ├── IOHIDCheckAccess(listenEvent) == .granted ───┐
          │                                                │
          ├── IOHIDCheckAccess(listenEvent) == .denied ────┼──► (no auto-prompt; UI shows "Denied" + "Open Settings" CTA)
          │                                                │
          └── IOHIDCheckAccess(listenEvent) == .unknown ───┴──► IOHIDRequestAccess(listenEvent) → TCC dialog
                                                                ├── user grants → installTap()
                                                                └── user denies → record(.denied(nowMs))

granted (cached) ──next agent start──► IOHIDCheckAccess re-check
                                       ├── still .granted → installTap()
                                       └── .denied (user revoked) → no installTap; permission store updates

denied(t) ──user opens Settings + grants──► IOHIDCheckAccess flips to .granted automatically
                                            (collector re-checks on next start)
```

### CGEventTap callback discipline (HARD won't-list)

```swift
private nonisolated func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // 1. Auto-recovery on tap drop
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        CGEvent.tapEnable(tap: self.machPort!, enable: true)
        return nil
    }
    // 2. Gate on lock/sleep — drop bucket increments while AFK
    if self.isLocked || self.isSleeping { return Unmanaged.passUnretained(event) }
    // 3. Counter-only — type discrimination ONLY
    switch type {
    case .keyDown:
        self.keystrokeCounter.atomicIncrement()
    case .leftMouseDown, .rightMouseDown,
         .mouseMoved, .leftMouseDragged, .rightMouseDragged,
         .scrollWheel:
        self.mouseCounter.atomicIncrement()
    default:
        break
    }
    // 4. NEVER calls event.getIntegerValueField(.keyboardEventKeycode)
    //    NEVER calls event.unicodeStringValue
    //    NEVER reads .modifierFlags
    //    NEVER reads .location
    return Unmanaged.passUnretained(event)
}
```

The callback is `nonisolated` (runs on tap's RunLoop source thread, not @MainActor). Counters are `Atomic<UInt32>` (Swift 5.10+ `Atomic` or `OSAllocatedUnfairLock`-wrapped Ints — choose by Swift toolchain). Flush is @MainActor — at minute boundary main hops, reads counters, writes row, resets counters atomically.

### Minute-boundary flush dispatch

```
CGEventTapCollector.runMinuteFlushLoop():
    while !Task.isCancelled:
        nowMs = currentMillisecondsSinceEpoch()
        nextBoundary = (floor(nowMs / 60_000) + 1) * 60_000
        try? await Task.sleep(nanoseconds: (nextBoundary - nowMs) * 1_000_000)
        if Task.isCancelled { break }

        await MainActor.run {
            let snapshot = (keystrokes: keystrokeCounter.exchange(0),
                            mouseMoves: mouseCounter.exchange(0),
                            appSwitches: appSwitchCounter.exchange(0),
                            foregroundApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            let bucketMs = floor(nextBoundary / 60_000 - 1) * 60_000  // bucket just-completed

            // Always upsert — even zero rows fill the timeline (useful for "user away")
            try? intensityAggregatesStore.upsert(
                minuteBucketMs: bucketMs,
                keystrokes: snapshot.keystrokes,
                mouseMoves: snapshot.mouseMoves,
                appSwitches: snapshot.appSwitches,
                foregroundApp: snapshot.foregroundApp
            )

            // Emit event only if any activity OR system-gating dropped the bucket
            if snapshot.keystrokes + snapshot.mouseMoves + snapshot.appSwitches > 0 {
                writer.enqueue(RawEvent(signalType: .context, bundleID: nil, payload: [
                    "event_kind": "intensity_snapshot",
                    "keystroke_count": snapshot.keystrokes,
                    "mouse_move_count": snapshot.mouseMoves,
                    "app_switch_count": snapshot.appSwitches,
                    "foreground_app": snapshot.foregroundApp ?? ""
                ]))
            } else if isLocked || isSleeping {
                writer.enqueue(RawEvent(signalType: .context, bundleID: nil, payload: [
                    "event_kind": "intensity_bucket_dropped",
                    "state": isLocked ? "locked" : "sleeping"
                ]))
            }
        }
```

### Event payload shapes

All S3 events use `SignalType.context`. Payloads minimal:

| event_kind | Payload |
|---|---|
| `intensity_snapshot` | `{event_kind, keystroke_count: Int, mouse_move_count: Int, app_switch_count: Int, foreground_app: String}` |
| `intensity_bucket_dropped` | `{event_kind, state: "locked"\|"sleeping"}` |
| `audio_route_changed` | `{event_kind, audio_route: "builtin"\|"headphones"\|"bluetooth"\|"airplay"\|"usb"\|"displayPort"\|"hdmi"\|"unknown"}` |
| `mic_in_use_entered` | `{event_kind, state: "mic_in_use"}` |
| `mic_in_use_exited` | `{event_kind, state: "mic_idle"}` |
| `display_connected` | `{event_kind, state: "display_connected"}` |
| `display_disconnected` | `{event_kind, state: "display_disconnected"}` |
| `vpn_state_changed` | `{event_kind, state: "connected"\|"disconnected"}` |
| `wifi_state_changed` | `{event_kind, state: "connected"\|"disconnected"}` |
| `clipboard_event_count` | `{event_kind, count: Int}` |
| `screenshot_taken` | `{event_kind, filename: String}` |
| `download_added` | `{event_kind, filename: String}` |
| `trash_changed` | `{event_kind, action: "added"\|"emptied"}` |

### File touches

| File | Change |
|---|---|
| `Packages/LeafCore/Sources/LeafCore/OS/SystemObserversStore.swift` | NEW — cross-process UserDefaults store; ObservableObject + @unchecked Sendable + NSLock cache; 10 observer keys |
| `Packages/LeafCore/Sources/LeafCore/OS/InputMonitoringPermissionStore.swift` | NEW — @MainActor actor; UserDefaults-backed; 24h denial backoff; probe via IOHIDCheckAccess |
| `Packages/LeafCore/Sources/LeafCore/OS/AudioRouteCategory.swift` | NEW — 8-case enum boundary |
| `Packages/LeafCore/Sources/LeafCore/OS/AudioRouteStateMachine.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/MicInUseStateMachine.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/DisplayStateMachine.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/VPNStateMachine.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/WiFiStateMachine.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/ClipboardCounterStateMachine.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/IntensityBucketAccumulator.swift` | NEW — minute-boundary flush logic, testable in pure Swift |
| `Packages/LeafCore/Sources/LeafCore/OS/ScreenshotMatcher.swift` | NEW — locale regex bank + extension whitelist |
| `Packages/LeafCore/Sources/LeafCore/OS/DownloadsMatcher.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/OS/TrashMatcher.swift` | NEW — coalesce 2s + action discrimination |
| `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M018_IntensityAggregates.swift` | NEW |
| `Packages/LeafCore/Sources/LeafCore/DB/IntensityAggregatesStore.swift` | NEW — DAO |
| `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` | EDIT — register M018; +5 `EventPayloadKeys` constants |
| `Packages/LeafCore/Sources/LeafCore/Maintenance/MaintenanceScheduler.swift` | EDIT — retention extends to `intensity_aggregates` table |
| `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` | EDIT — +13 enum cases + 13 default OFF entries |
| `Packages/LeafCore/Sources/LeafCore/Agent/AgentThresholds.swift` | EDIT — +5 fields with weakDefaults |
| `LeafAgent/Collectors/CGEventTapCollector.swift` | NEW |
| `LeafAgent/Collectors/AudioRouteCollector.swift` | NEW |
| `LeafAgent/Collectors/MicInUseCollector.swift` | NEW |
| `LeafAgent/Collectors/DisplayCollector.swift` | NEW |
| `LeafAgent/Collectors/VPNCollector.swift` | NEW |
| `LeafAgent/Collectors/WiFiCollector.swift` | NEW |
| `LeafAgent/Collectors/ClipboardCollector.swift` | NEW |
| `LeafAgent/Collectors/LocalFilesWatcher.swift` | NEW |
| `LeafAgent/Agent.swift` | EDIT — construct + start + stop 8 collectors; AgentLifetime +8 slots |
| `LeafAgent/Info.plist` | NO CHANGE — Input Monitoring uses macOS-default prompt (no usage description key) |
| `Leaf/Models/PermissionsService.swift` | EDIT — +inputMonitoringGranted + 3 methods + systemObserversStore inject |
| `Leaf/Views/Window/Settings/SystemObserversSettingsSection.swift` | NEW — 10 per-observer rows + Input Monitoring CTA |
| `Leaf/Views/Window/Settings/SettingsView.swift` (integration point) | EDIT — insert SystemObserversSettingsSection between PrivacySettingsSection and LocalAppsSettingsSection |
| `Packages/LeafCore/Tests/LeafCoreTests/SystemObserversStoreTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/InputMonitoringPermissionStoreTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/AudioRouteStateMachineTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/MicInUseStateMachineTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/DisplayStateMachineTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/VPNStateMachineTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/WiFiStateMachineTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/ClipboardCounterStateMachineTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/IntensityBucketAccumulatorTests.swift` | NEW — minute boundary + reset + zero-row upsert |
| `Packages/LeafCore/Tests/LeafCoreTests/ScreenshotMatcherTests.swift` | NEW — locale fixtures (en/ru/de/fr/es/ja/ko/zh) + extension filter + non-screenshot rejection |
| `Packages/LeafCore/Tests/LeafCoreTests/DownloadsMatcherTests.swift` | NEW |
| `Packages/LeafCore/Tests/LeafCoreTests/TrashMatcherTests.swift` | NEW — added vs emptied vs coalesce |
| `Packages/LeafCore/Tests/LeafCoreTests/IntensityAggregatesStoreTests.swift` | NEW — upsert idempotence + range read + retention purge |
| `Packages/LeafCore/Tests/LeafCoreTests/ShareEventTypeRegistryS3Tests.swift` | NEW — registry size 152 + 13 default OFF |
| `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` | EDIT — +13 walkbacks (one per new event_kind) |
| `Packages/LeafCore/Tests/LeafCoreTests/CGEventTapNoContentLeakageTests.swift` | NEW — source-grep on CGEventTapCollector.swift + IntensityBucketAccumulator.swift + tap-callback signature audit |
| `Packages/LeafCore/Tests/LeafCoreTests/S3CollectorSourceGrepTests.swift` | NEW — per-collector forbidden-API substring checks (NSPasteboard.pasteboardItems / AVCaptureDevice / `.characters` / SSID / etc) |
| `.claude/shared/current-state.md` | EDIT — closing note for S3 + Track-4 stack status |

No new SQLCipher tables besides M018. No `leaf-relay` changes. No `Leaf.xcodeproj/project.pbxproj` edits (LeafAgent Info.plist embedded since S1; no new plist keys in S3). No LeafCorePrivate (moat) changes — all S3 surfaces are public substrate (no PII catalogues / no per-vendor adapters / no obfuscation needed; the only "moat" candidate would be locale-aware screenshot regex bank, but that's clearly substrate-level and lives in public).

## Permissions UX

### TCC entries

- **Input Monitoring** (new in S3) — required for CGEventTap to receive `.keyDown` events. Triggered via `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)`. Fires under `tech.gundem.leaf.agent` (the binary that actually installs the tap). Main app also surfaces the permission status (read-only — main app doesn't install taps) so the Settings UI can show state.
- **Accessibility (AX)** — already granted via Onboarding in S1. Required for `.mouseMoved` / `.mouseDragged` events in CGEventTap (Apple lumps mouse events with AX in addition to Input Monitoring for keystrokes — both required for full intensity).
- **Full Disk Access (FDA)** — already granted via Onboarding. Required for FSEvents over `~/Desktop`, `~/Downloads`, `~/.Trash`.
- **No NSMicrophoneUsageDescription needed** — CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` listener does not capture audio, does not actuate the green-dot mic indicator, does not require TCC.
- **No Location TCC prompt** — WiFi is state-only (no SSID read).

### Settings → Privacy → System Observers screen (new)

Layout (mirror S2 Local Apps section structure):

```
LeafSection "System observers"
  ╭─ LeafCard.subdued (header) ───────────────────────────╮
  │ System observers                                       │
  │ Background observers capture context shifts — audio    │
  │ routing, displays, voice calls, downloads. Everything  │
  │ here is local-only by default; Share Controls gate     │
  │ what reaches your team.                                │
  ╰────────────────────────────────────────────────────────╯
  ╭─ LeafCard.raised (per observer row × 10) ─────────────╮
  │ [icon] Intensity (keystroke/mouse counters)            │
  │                          [Permission needed] [Toggle]  │
  │   └── (drawer when ⓘ expanded)                        │
  │       Counts keystrokes + mouse moves per minute.      │
  │       Never captures key content or mouse position.    │
  │       Requires Input Monitoring permission.            │
  │       [Open System Settings → Input Monitoring]        │
  ╰────────────────────────────────────────────────────────╯
  ... (9 more rows — audio_route / mic_in_use / display / VPN / WiFi
       / clipboard / screenshot_watcher / downloads_watcher /
       trash_watcher; permission badges hidden for non-TCC rows)
```

Permission badge mapping for Intensity row:
- `notRequested` → "Waiting" (gray)
- `granted` → "Granted ✓" (green)
- `denied(t)` → "Denied" (red) + LeafBanner.warning "Click to open System Settings → Input Monitoring"
- `unavailable` → "Unavailable" (gray) + "Retry" button

Other 9 rows have no badge (no TCC) — just toggle.

Settings → Privacy section (`PrivacySettingsSection.swift`) — **NOT extended directly**. New section `SystemObserversSettingsSection` is its own root in Settings tab between Privacy and LocalApps. Reasoning: Privacy section already conceptually overloaded (AX + FDA + Calendar + Focus rows); adding 10 more would overcrowd it.

### Onboarding flow

**NOT extended** per Track-4 contract §S3 ("master toggles in Privacy section"). Intensity is on-demand opt-in via Settings. No new Onboarding step.

## Privacy walkbacks (mandatory)

Per Track-4 contract §"S3 Privacy regression tests" + ADR-010 §6 (whitepaper Won't-list):

1. **`CGEventTapNoContentLeakageTests`** — dedicated test file. Three layers:
   - **Source-grep** on `LeafAgent/Collectors/CGEventTapCollector.swift` — comment-stripped — scanned for forbidden API substrings:
     - `event.getIntegerValueField(.keyboardEventKeycode)` / `keyboardEventKeycode`
     - `event.unicodeStringValue` / `unicodeString`
     - `.characters` (in CGEvent context — careful not to match `NSCharacterSet` etc; regex tightens via word-boundary on `event\.`)
     - `getDoubleValueField` (mouse position fields)
     - `.modifierFlags`
     - `.location` (read off CGEvent — careful not to match `URL.location` etc; regex tightens via `event\.location` substring)
   - **Source-grep** on `Packages/LeafCore/Sources/LeafCore/OS/IntensityBucketAccumulator.swift` — same list; ensures even pure-Swift state machine doesn't accidentally introduce a content read path.
   - **Runtime test** — invoke `IntensityBucketAccumulator.observe(snapshot:)` 100 times with fixtures; assert emitted RawEvent payload contains **only** keys `event_kind`, `keystroke_count`, `mouse_move_count`, `app_switch_count`, `foreground_app` — and NO other key.

2. **`S3CollectorSourceGrepTests`** — per-collector forbidden-API substring checks:
   - **ClipboardCollector** — forbidden: `pasteboardItems`, `string(forType:`, `data(forType:`, `propertyList`
   - **MicInUseCollector** — forbidden: `AVCaptureDevice`, `AVAudioRecorder`, `AVAudioEngine`, `kAudioInputCallback` (capturing audio)
   - **AudioRouteCollector** — forbidden: `kAudioDevicePropertyDeviceName`, `kAudioObjectPropertyName`, `kAudioDevicePropertyDeviceManufacturer` (device-name reads)
   - **WiFiCollector** — forbidden: `.ssid()`, `.bssid()`, `kCWInterfaceModeSSID`, `requestLocationAuthorization`
   - **DisplayCollector** — forbidden: `CGDisplayCreateImage`, `CGWindowListCreateImage`, `ScreenCaptureKit`, `CGImage` (no screen capture path)
   - **LocalFilesWatcher** — forbidden: `Data(contentsOf:`, `String(contentsOf:`, `FileHandle(forReadingAt:`, `FileManager.contents(atPath:` (reads file content)
   - **VPNCollector** — forbidden: `serverAddress`, `username`, `passwordReference` (VPN config secrets)
   - **CGEventTapCollector** — same as walkback #1

3. **`RelayBodyLeakageTests` extension — +13 walkbacks** (one per new event_kind). Each constructs adversarial `RawEvent` payload with PII marker (e.g., `"body": "SECRET-KEY-CONTENT-MARKER-S3"` injected in `intensity_snapshot` payload, or `"track_name": "..."`-style PII smuggled into `audio_route_changed`) → writes via `writeEventsOffsetAndPresence` → asserts `presence_state.state_json` doesn't contain the marker. Mirrors S2's 14 walkback extensions; total walkbacks count 48 (S2 ship) → **61 (+13)**.

4. **`SystemObserversStore` default verification** — `SystemObserversStoreTests.testDefaults` asserts:
   - `isEnabled("intensity") == false` (default OFF — TCC + battery)
   - `isEnabled("clipboard") == true`
   - All other 8 observers → `isEnabled == true`

5. **`ShareEventTypeRegistryS3Tests.testAllS3KeysDefaultOff`** — every new ShareEventTypeKey case has `defaultEnabled == false` per ADR-020 (broadcast vs capture distinction; local capture defaults per SystemObserversStore, share defaults to OFF universally for S3).

## Test plan

TDD sequential per CLAUDE.md "Одна phase = одна сессия" → Stage 5 ("write failing test → run → see fail → implement → run → see pass → commit; after every step all tests still pass").

### Test count delta

| Layer | Tests |
|---|---|
| Baseline (Track-4 S2 ship) | 1847 |
| `SystemObserversStore` (defaults / set+read / cross-process UserDefaults round-trip / observable updates) | +6 |
| `InputMonitoringPermissionStore` (24h denial backoff / state transitions / UserDefaults round-trip) | +5 |
| `AudioRouteStateMachine` (transition emission / no-op collapse / unknown→known) | +5 |
| `MicInUseStateMachine` (0→1 / 1→0 / no flap on same-value) | +4 |
| `DisplayStateMachine` (add / remove / mode-change ignored / multi-display) | +5 |
| `VPNStateMachine` (stable-state transitions / intermediate ignored / KVO replay safety) | +5 |
| `WiFiStateMachine` (connected ↔ disconnected / mode change while connected / power-off mid-state) | +5 |
| `ClipboardCounterStateMachine` (delta > 0 emit / delta == 0 no-emit / counter wrap) | +4 |
| `IntensityBucketAccumulator` (minute-boundary flush / counter reset / zero-row upsert / locked-bucket drop emission / SystemState gating / app-switch sibling counter) | +10 |
| `ScreenshotMatcher` (en / ru / de / fr / es / ja / ko / zh / it locale fixtures + extension filter + non-match rejection + custom prefix) | +12 |
| `DownloadsMatcher` (created-file detection / directory ignored / hidden-file ignored / coalesce dedup) | +5 |
| `TrashMatcher` (added vs emptied discrimination / coalesce 2s burst / multi-file batch) | +5 |
| `IntensityAggregatesStore` (upsert idempotence / range read / retention purge / FK / unique PK) | +6 |
| `ShareEventTypeRegistryS3Tests` (size 152 / 13 cases registered / all default OFF / enum case raw value consistency) | +4 |
| `RelayBodyLeakageTests` extension (+13 walkbacks) | +13 |
| `CGEventTapNoContentLeakageTests` (3 source-grep + 1 runtime payload audit + 1 callback-signature audit) | +5 |
| `S3CollectorSourceGrepTests` (per-collector forbidden API; 8 collectors) | +8 |
| `MaintenanceSchedulerRetentionTests` extension (intensity_aggregates purge alongside events purge) | +2 |
| **Target** | **~1957 (1847 + 109 new ± 10 tolerance)** |

### Build verification

After every implementation step:
1. `swift test --package-path Packages/LeafCore` — all green
2. `just check-tokens` + `just check-tokens-self-test` — both PASS
3. `just build-all` — 5/5 xcodebuild schemes (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP) green

## Acceptance criteria

- **AC1:** All 1847 baseline SPM tests pass; **~1957 total** after S3 ship (1847 + 109 new ± 10 tolerance).
- **AC2:** 5/5 xcodebuild schemes green (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP).
- **AC3:** `just check-tokens` PASS + `just check-tokens-self-test` PASS.
- **AC4:** `ShareEventTypeKey.allCases.count == 152` (139 baseline + 13 new); `ShareEventTypeDefaults.all.count == 152`; every new key has `defaultEnabled == false`.
- **AC5:** Migration M018 produces a valid `intensity_aggregates` table — `Database.openForWrite` succeeds on a fresh DB; `IntensityAggregatesStore.upsert + read` round-trips correctly.
- **AC6:** Manual smoke on Author's Mac:
  - Cold install → Settings → System Observers section visible between Privacy and Local Apps. 10 observer rows; intensity toggle OFF default, 9 others ON default.
  - Toggle Intensity ON → TCC prompt fires for Input Monitoring under `tech.gundem.leaf` (or `tech.gundem.leaf.agent` on first poll). Grant → "Granted ✓" badge. Restart agent (or trigger via `launchctl kickstart -k`). After agent restart: type 50 keystrokes within one minute + move mouse. After minute-boundary: `intensity_aggregates` row appears with `keystrokes >= 50`, `mouse_moves > 0`, `foreground_app != null`. AND `events` table has matching `intensity_snapshot` row.
  - Plug in headphones → `audio_route_changed` event with `audio_route: "headphones"` (or `"bluetooth"` for AirPods).
  - Open Voice Memos / start QuickTime recording → `mic_in_use_entered`. Stop → `mic_in_use_exited`.
  - Plug in external monitor → `display_connected`. Unplug → `display_disconnected`.
  - Toggle macOS built-in VPN (System Settings → Network → VPN) → `vpn_state_changed` with appropriate state.
  - Toggle WiFi OFF then ON → `wifi_state_changed` two events: disconnected, then connected.
  - Copy text 5 times within a minute → `clipboard_event_count` with `count: 5`.
  - Take a screenshot via ⌘⇧3 → `screenshot_taken` event within 2s with filename matching locale pattern.
  - Drop a file in `~/Downloads` → `download_added` event.
  - Drag file to Trash → `trash_changed: added`. Empty Trash → `trash_changed: emptied`.
  - Lock screen via ⌃⌘Q → no `intensity_snapshot` events for the lock period; instead `intensity_bucket_dropped: locked` rows appear in `events` table per minute. Unlock → `system_unlocked` (S1 collector) → next minute boundary resumes normal `intensity_snapshot` emission.
  - Deny Input Monitoring → toggle Intensity ON → "Denied" badge + "Open System Settings" CTA visible. Click CTA → System Settings → Privacy → Input Monitoring opens correctly. Wait 23h59m + toggle ON again → no re-prompt (24h cache). Wait 24h + 1min + toggle ON → re-probe fires.
  - Toggle Clipboard OFF → copy text → no `clipboard_event_count` events emitted.
- **AC7:** `CGEventTapNoContentLeakageTests` passes — source-grep on `CGEventTapCollector.swift` returns ZERO matches for forbidden API substrings; runtime payload audit confirms emitted RawEvent payloads contain ONLY allowed keys.
- **AC8:** `S3CollectorSourceGrepTests` passes — all 8 forbidden-substring lists clean across collector sources.
- **AC9:** `RelayBodyLeakageTests` extension (+13 walkbacks) passes. Adversarial payloads with PII markers (e.g. `"body": "SECRET-S3-MARKER"`) do NOT leak in `presence_state.state_json`.
- **AC10:** `IntensityAggregatesStore` retention works — populating with 100 rows spanning `retentionDays + 1` days, then calling `MaintenanceScheduler.runRetention()`, deletes rows older than cutoff while preserving in-window rows.
- **AC11:** SystemStateCollector gating verified — manually lock screen for 90s + type 200 keystrokes (against unlock prompt). After unlock, check DB: `intensity_aggregates` rows during locked window are present but with `keystrokes == 0` (callback dropped them via `isLocked` early-return); `intensity_bucket_dropped` rows ARE present for the lock duration.
- **AC12:** No Info.plist changes — verify via `otool -P build/Debug/LeafAgent | grep NSInputMonitoring` returns nothing (Apple's Input Monitoring uses macOS-default prompt, no usage description key).

## Risks

- **R1 (high):** CGEventTap callback isolation — race on Atomic counters under fast typing (>10 keys/s) could under-count. **Mitigation** — use OSAllocatedUnfairLock-wrapped Ints with `withLock { counter += 1 }`, or `Atomic<UInt32>` (Swift 5.9+) — both faster than locks in tap context. Benchmark in plan Stage 5.
- **R2 (medium):** CGEventTap battery impact — Track-4 contract OQ-2 flagged this. **Mitigation** — `.listenOnly` mode + counter-only callback (single increment per event) should be <0.1% baseline drain. Defer real measurement to Stage 7 verification on Author's Mac (Power Profiler comparison: baseline vs S3-active for 30min coding session). If >2% drain → swap to sampling mode (every Nth event counted) in S3 polish, before merge.
- **R3 (medium):** Input Monitoring TCC prompt friction — Apple shows a generic system dialog ("Leaf would like to monitor input from your keyboard"). Some users will deny outright. **Mitigation** — Settings UI shows explicit explainer drawer when user clicks Intensity Toggle (BEFORE TCC fires) so user understands what's being requested. Skip-without-loss path documented; non-intensity observers continue normally.
- **R4 (low):** Locale-aware ScreenshotMatcher regex bank coverage — 10 locales pinned (en, ru, de, fr, es, ja, ko, zh, it, pt). Other locales (ar / he / hi / tr / pl / nl / sv / no / da / fi / etc) miss the pattern. **Mitigation** — locale list pinned to MVP user base (USA / EU / Asia majors). Add locale on demand. ScreenshotMatcher exposes `additionalPatterns: [String]` injection point for runtime extension in S4 polish.
- **R5 (low):** NEVPNManager.shared() limits S3 to first-system-VPN observability only. Third-party Network Extension VPNs (Cloudflare WARP / Tailscale / NordVPN / etc) won't surface. **Mitigation** — document in OQ-S3-5 + Risk section; user can complement with future Network Framework integration if signal proves important.
- **R6 (low):** FSEvents bursts on `~/Downloads` during Safari multi-resource page save (50+ files in 1s) — could flood `download_added` events. **Mitigation** — 2s coalesce window via DownloadsMatcher; if 50 events in 2s → emit one `download_added` with `{count: 50, filename: <last>}` (state machine collapses). Tune coalesce window in S3 polish if real-world data shows issue.
- **R7 (low):** `CWWiFiClient.shared().interface()` returns nil on machines without WiFi hardware (Mac Pro tower, Mac mini wired-only). **Mitigation** — WiFiCollector guards on nil; logs once + no-op startup; no crash.
- **R8 (very low):** Atomic counter overflow if user types >4 billion keystrokes per minute. Comedy. **Mitigation** — UInt32 supports 4.3B ops/min ≈ 71M ops/sec; impossible from human input.
- **R9 (medium):** Auto-restart on tap drop — `kCGEventTapDisabledByTimeout` callback fires after system suspects the tap is taking too long. Should be infrequent in `.listenOnly` + counter-only mode, but a sudden burst could trigger. **Mitigation** — auto-restart logic emits a log entry; restart logic is idempotent and cheap. Document failure mode in OQ-S3-7.

## Dependencies

- ✅ Track-4 S1 ship (`feature/track-4-S1-architecture-catch-up` tip merged into S2 base) — provides `SystemStateCollector.isLocked` / `.isSleeping` consumption point + S1 OnboardingService FDA grant + S1 Settings privacy section substrate.
- ✅ Track-4 S2 ship (`feature/track-4-S2-applescript-surface` tip `8489a6e`) — provides 1847 SPM baseline + `LocalAppsStore` cross-process UserDefaults pattern + `AppleScriptPermissionStore` 24h denial-backoff pattern + `LocalAppsSettingsSection` UI substrate.
- ✅ Track-2 D4 — Settings tokens substrate.
- ❌ Track-4 S4 (Substrate Integration — registry expansion + FTS dispatcher + iconography) — does NOT block S3; S3 ships substrate, S4 ships integration polish.
- ❌ Track-5 UI-A (shell redesign) — does NOT block S3 (capture-only).
- No `leaf-relay` changes.
- No external API providers.

## Open questions

- **OQ-S3-1 (foreground app for intensity row — single snapshot vs intra-minute majority):** Current spec snapshots `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` at flush-tick (minute boundary). Alternative: track per-minute "majority app" via intra-minute polling. **Decision:** single snapshot. **Reasoning:** intra-minute polling adds Task complexity + storage cost (per-minute app-time table) for marginal benefit; per-minute majority app rarely diverges from flush-time snapshot in real usage. Add as S4 polish if Derived Insights wants accuracy.
- **OQ-S3-2 (intensity bucket dropped semantics):** Currently `intensity_bucket_dropped` event_kind emits on locked/sleeping minutes. Alternative: don't emit at all (rely on absence of `intensity_snapshot`). **Decision:** emit. **Reasoning:** explicit AFK signal is more useful than implicit absence; allows Derived Insights to distinguish "user was AFK" from "no data yet" (e.g. first minute after start). Default OFF in registry → user can opt out if they consider lock-state-tracking sensitive.
- **OQ-S3-3 (WiFi SSID capture — closed above):** State-only (no SSID). Sub-toggle in S4 polish if demand emerges. **Reasoning:** SSID requires Location TCC (extra prompt friction) + SSID = PII. State signal sufficient for "user moved network".
- **OQ-S3-4 (Bluetooth — closed via Track-4 contract OQ-5):** Skipped. Low signal-to-cost ratio + device names = PII + IOBluetooth API complexity. Revisit post-MVP if feedback shows demand.
- **OQ-S3-5 (third-party VPN via Network Extension):** NEVPNManager.shared() only observes first system-configured VPN. Cloudflare WARP / Tailscale / etc are Network Extension framework providers — not visible via NEVPNManager. **Decision:** best-effort S3 capture, document limitation. **Reasoning:** NEHotspotHelper / NEFilterProvider observability is involved (entitlement-gated, doesn't list user-installed extensions per-se). Defer to v1.1 if signal proves critical.
- **OQ-S3-6 (CGEventTap event mask — keystrokes + mouse + scroll vs subset):** Current mask includes keystrokes, all mouse buttons, drag, move, scroll. Alternative: drop `.mouseMoved` (most events; ~1000/s during cursor movement, dominates counter) and rely on click/scroll/drag/keystroke as activity proxies. **Decision:** include `.mouseMoved`. **Reasoning:** mouse-moved is a strong "user is at keyboard, not AFK" signal even without clicks (reading scrollable content). Counter aggregation flattens the volume. If callback latency surfaces as battery issue (R2), drop `.mouseMoved` in S3 polish.
- **OQ-S3-7 (CGEventTap auto-restart logging):** Auto-restart logic emits log entry on every restart. Could be noisy in pathological cases. **Decision:** keep logging at `.info` level (not `.error`); add `osLog signpost` for diagnostic purposes if real-world prevalence surfaces. Track-4 contract §S3 mentions "Auto-restart logic if tap drops (macOS Sonoma+ resilience)" — no further detail.
- **OQ-S3-8 (Master toggle live reconfiguration):** Currently, toggling intensity ON mid-session does NOT install the tap until next agent restart. Alternative: live-reconfigure via NSDistributedNotificationCenter or shared signal. **Decision:** restart-required. **Reasoning:** mid-tap reconfiguration is complex (must drain in-flight counters, persist partial bucket, re-install RunLoop source) + low-frequency operation (users rarely toggle intensity once decided). Document UX in Settings: "Restart Leaf to apply intensity changes" banner appears after toggle.
- **OQ-S3-9 (Schema migration number — M015 vs M018):** Track-4 contract §S3 mentioned "M015". Recon showed latest landed migration is M017. **Decision:** M018. **Reasoning:** contract was written 2026-05-11, Track-1 D2 + Track-3 D1/D2 + Linear reconciliation consumed M012-M017 between contract write and S3 implementation. Use next available.
- **OQ-S3-10 (Locale list for ScreenshotMatcher):** Pinned 10 (en/ru/de/fr/es/ja/ko/zh/it/pt). Should be expandable? **Decision:** pin + expose `additionalPatterns: [String]` injection for runtime extension in moat configs (LeafCorePrivate `ProdConfigs.screenshotAdditionalPatterns`). S3 ships pinned list; moat can add per-customer locale support without recompile-shipping new substrate.
- **OQ-S3-11 (counter atomicity — Atomic<UInt32> vs OSAllocatedUnfairLock):** Swift 5.9+ has `Atomic`; Swift 5.10+ has the `synchronization` module formalised. Project targets Swift 6+. **Decision:** use `OSAllocatedUnfairLock`-wrapped `UInt32` — simpler reasoning, no Swift toolchain version assumption, guarantee of memory ordering. Performance acceptable (lock acquire is ~10-30ns; well below CGEventTap callback throughput needs).
- **OQ-S3-12 (Mic in-use via CoreAudio vs AVAudioSession.recordPermission):** AVAudioSession is iOS-only on macOS; macOS has its own audio session API but it's a moving target. CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` is rock-solid, kernel-level, no TCC. **Decision:** CoreAudio. **Reasoning:** clean, no permission prompt, generic across all consumers.
- **OQ-S3-13 (Display events — emit on rotation/mode change too?):** Currently only emit on `addFlag` / `removeFlag`. Mode-change (resolution / refresh-rate / rotation) currently ignored. **Decision:** ignore. **Reasoning:** mode-change is too noisy (HiDPI scaling auto-toggles); context-shift signal preserved by add/remove only.

## Workflow per CLAUDE.md "Одна phase = одна сессия"

Eight stages. S3 spec covers Stages 1-3; S3 plan (same session per user direction "иду в зал — спек и план оба сразу") covers Stage 4. Stages 5-8 happen in next session.

1. ✅ Discovery (Stage 1) — done: contract read, S1+S2 specs + plans form-mirrored, Explore subagent substrate snapshot returned, key files (`SystemStateCollector` / `LocalAppsStore` / `AgentThresholds` / `Agent.swift` / `PermissionsService`) verified directly.
2. ✅ Brainstorm (Stage 2) — done: 13 OQ-S3-* closed inline; major decisions — (a) skip Bluetooth, (b) WiFi state-only no SSID, (c) Mic via CoreAudio no TCC, (d) per-collector pattern not orchestrator, (e) M018 not M015, (f) restart-required for intensity toggle.
3. ✅ Spec write (Stage 3) — **this document**.
4. ⏭ Plan (Stage 4) — **same session continuation**; file `docs/superpowers/plans/2026-05-13-track-4-S3-system-observers-and-intensity.md`.
5. ⏭ Implementation (Stage 5) — TDD sequential per plan, **separate session**.
6. ⏭ Independent review (Stage 6) — `superpowers:code-reviewer` subagent.
7. ⏭ Verification (Stage 7) — `superpowers:verification-before-completion` skill; manual smoke per AC6 on Author's Mac.
8. ⏭ Ship (Stage 8) — final commit `docs(shared): Phase Track-4 S3 landed — current-state update`. **NO push, NO merge** — Track-4 stack waits collective merge after S4 + Track-4 acceptance gate per Track-4 contract §"Phase decomposition order".

## Post-S3 path

S3 lands as a substrate-only sub-phase. After ship:

1. **Track-4 S4 work starts in separate session** — Substrate Integration (registry expansion publishing / FTS body-kind dispatcher additions for title-bearing kinds / iconography per event_kind in Activity tab / `share_event_types` runtime persistence). Off `feature/track-4-S4-substrate-integration`, baselined on S3 ship tip.
2. **No Track-4 acceptance gate yet** — gate fires after S4 per contract §"Acceptance criteria (per sub-phase)" matrix. S3 individual smoke validates S3 alone (per AC6 above).
3. **No whitepaper sync** — Track-4 contract §"Phase decomposition order" states whitepaper sync deferred until post-S4 collective merge. Architecture.md drift (it currently describes CGEventTap, NSPasteboard, FSEvents widening as "in Layer A" without specific collectors) gets reconciled then.
4. **Carry-forward to S4:** `intensity_aggregates` table → Derived Insights Engine consumers (deepWorkStreak / peakProductivityHour). FTS body-kind dispatcher — should `screenshot_taken` / `download_added` filenames be FTS-indexed for Activity tab search? S4 design.
