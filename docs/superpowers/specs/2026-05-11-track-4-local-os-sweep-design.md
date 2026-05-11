# Track 4 — Local OS Activity Sweep

**Date:** 2026-05-11
**Status:** Draft (brainstorm-approved, awaiting per-sub-phase implementation plan)
**Owner:** Dmitrii

## Context

Recon (2026-05-11) показал реальный baseline Layer A:

**Существующие collectors:**
- ✅ `ActiveAppCollector` (`LeafAgent/Collectors/ActiveAppCollector.swift`) — NSWorkspace.didActivateApplication + 30s AX polling (window title + browser URL via AXWebArea BFS, max title 200ch, max URL 1024ch)
- ✅ `IdleCollector` (`LeafAgent/Collectors/IdleCollector.swift`) — CGEventSource.secondsSinceLastEventType
- ✅ `FSEventsCollector` (`Packages/LeafCore/Sources/LeafCore/Collectors/FSEventsCollector.swift`) — user-configured watched folders only (no hardcoded paths)
- ✅ `ClaudeCodeCollector` (`Packages/LeafCore/Sources/LeafCore/Collectors/ClaudeCodeCollector.swift`) — jsonl tail из `~/.claude/projects/<slug>/*.jsonl`

**Architecture.md обещало, но НЕ реализовано:**
- ❌ EventKit / Calendar — нет
- ❌ INFocusStatusCenter / Focus mode — нет
- ❌ DistributedNotificationCenter sleep/wake/screen-lock — нет
- ❌ AppleScript / NSAppleScript — entirely absent
- ❌ CGEventTap — entirely absent
- ❌ NSPasteboard observers — нет
- ❌ Audio / VPN / WiFi / Display / Bluetooth / Mic observers — нет

Track 4 имеет **два слоя**: architecture catch-up (S1, реализация того что architecture.md описывало но не было) + новое coverage (S2 AppleScript + S3 system observers + intensity).

## Scope

**In-scope:**
- Architecture catch-up: Calendar / Focus / lock-state / spaces (S1)
- AppleScript dictionaries для ~10 apps (S2)
- CGEventTap intensity counters с privacy regression test (S3)
- System observers: audio / mic / display / VPN / WiFi / Bluetooth / clipboard (S3)
- FSEvents widening: screenshots / Downloads / Trash (S3)
- ShareEventTypeKey registry expansion (S4)
- Substrate integration (S4)

**Out-of-scope (ADR-010 won't-list):** screen recording, OCR canvas, keylogging content, captured UI events of foreign apps. **Out-of-scope (privacy / perms):** iMessage (full disk access + PII), Universal Control state, NotificationCenter introspection, Spotlight searches, Quick Look. **Out-of-scope (separate track):** Layer D plugins (Figma plugin / VSCode extension / Chrome extension).

## Approach

4 sequential sub-phase'а:

### S1 — Architecture catch-up

Реализация того что architecture.md описывало в Layer A:

| Collector | Source API | Emitted event_kinds |
|---|---|---|
| `CalendarCollector` | EventKit (`EKEventStore.requestFullAccessToEvents`) | `meeting_state_entered`, `meeting_state_exited` — **`in_meeting` boolean only, NO title / attendees / location** (privacy walkback) |
| `FocusModeCollector` | INFocusStatusCenter (`isFocused` property + change observation) | `focus_mode_enabled`, `focus_mode_disabled`, optionally `focus_mode_changed` (mode name if available) |
| `SystemStateCollector` | DistributedNotificationCenter (`screenIsLocked` / `screenIsUnlocked`) + NSWorkspace (sleep / wake) | `system_locked`, `system_unlocked`, `system_slept`, `system_woke` |
| `SpacesCollector` | NSWorkspace.activeSpaceDidChangeNotification | `space_switched` (workspace identifier as opaque counter, no space name capture) |

**Permission UX:** EventKit + Focus prompts добавляются в Onboarding (existing flow). Per architecture.md ~80% grant rate.

### S2 — AppleScript surface

**Generic substrate:**
- `AppleScriptBridge` — OSAScript invocation wrapper с timeout (e.g. 1s) + graceful error handling
- Per-app permission state cache (granted / denied / not-requested / unavailable) — 24h denial cache predict re-prompt spam

**Per-app adapters** (script bodies в LeafCorePrivate per CLAUDE.md pre-push moat rule):

| App | Captured signal | Privacy guard |
|---|---|---|
| Xcode | active doc path, project name, scheme, build state | path is L4 by default (folder ceiling); L5 (full path) opt-in |
| JetBrains IDEs (IntelliJ / PyCharm / WebStorm / GoLand / etc.) | project name, active file (if AS dict supports) | L4 default |
| Music | current track + artist + state (playing / paused) | none — context signal |
| Spotify | current track + artist + state | none |
| Apple Notes | active note **title only** | **never body** |
| Reminders | task completed (action event) | task body never |
| Calendar | visible date range | event title NEVER captured |
| Mail | active mailbox name | **default OFF** (mailbox name = PII); opt-in only |
| Zoom | meeting state + own meeting name only | attendee list never |
| Safari / Chrome / Arc | multi-tab titles + URLs | tab content / history never |

**Apps без AppleScript (только AX window title, already covered Phase 4.10.B):**
Slack desktop / Cursor / VS Code / Notion / Linear desktop / Discord / Telegram / WhatsApp / Figma / ChatGPT / Claude desktop / Firefox.

**Permission UX:**
- New Settings → "Local Apps" screen с per-app enable toggle + permission state badge
- Permission requested **on-demand** при первом toggle включении (НЕ batch на onboarding'е — иначе 10+ TCC prompts spam)
- Denial graceful: 24h cache, no re-prompt spam, UI shows "Permission denied — click to retry" state

### S3 — System observers + intensity

| Collector | Source API | Emitted event_kinds | Notes |
|---|---|---|---|
| `AudioRouteCollector` | AudioObjectAddPropertyListener (default output device) | `audio_route_changed` (headphones / speakers / external) | Cheap, event-driven |
| `MicInUseCollector` | AVCaptureDevice activeInputs polling 30s | `mic_in_use_entered`, `mic_in_use_exited` | Generic "in voice call" signal across all apps |
| `DisplayCollector` | CGDisplayRegisterReconfigurationCallback | `display_connected`, `display_disconnected` | Context-shift signal |
| `VPNCollector` | NEVPNManager.shared() status observer | `vpn_state_changed` | Cheap |
| `WiFiCollector` | CWWiFiClient | `wifi_ssid_changed` | **Default OFF** — SSID = PII |
| `BluetoothCollector` | IOBluetooth callbacks | `bluetooth_device_connected`, `bluetooth_device_disconnected` | **Low signal — consider skipping** (see OQ-5) |
| `ClipboardCounter` | NSPasteboard.changeCount diff per 60s tick | `clipboard_event_count` (1-minute bucket) | **Counter only, zero content** |
| `IntensityCounter` | CGEventTap `.listenOnly` mode | `intensity_keystroke_bucket`, `intensity_mouse_bucket` (per-minute aggregates) | **Counter only, zero content stored** — see privacy regression below |
| `ScreenshotWatcher` | FSEvents `~/Desktop` + locale-aware pattern | `screenshot_taken` | Filename pattern: en `Screen Shot*` / `Screenshot*`; ru `Снимок экрана*`; etc. |
| `DownloadsWatcher` | FSEvents `~/Downloads` | `download_added` | Filename only, no content |
| `TrashWatcher` | FSEvents `~/.Trash` | `trash_emptied` | Coarse event |

**CGEventTap privacy contract (HARD requirement):**
- `.listenOnly` mode (no event modification)
- Callback NEVER reads `.characters` / `.keycode` / `.modifierFlags` into storage
- Callback only increments per-minute counter — store nothing about the key itself
- Active only when not locked / not sleeping — subscribes к `SystemStateCollector` (S1) для enable / disable lifecycle
- Auto-restart logic if tap drops (macOS Sonoma+ resilience)
- **Privacy regression test** (mirror Track-1 D2 `RelayBodyLeakageTests` pattern) — `CGEventTapNoContentLeakageTests` asserts callback path never persists key content

### S4 — Substrate integration

- ShareEventTypeKey registry extended ~78 (Track 3 D4 baseline) → ~110-115 entries. All Track 4 entries **default OFF** per ADR-020.
- FTS body-kind dispatcher: skip large bodies, но index **titles / URLs / track names / file names** for searchability в Activity tab (Track 5 dependency).
- Activity tab per-event icons: add iconography для new local kinds (track name → music icon, screenshot → camera icon, mic-in-use → mic icon).

## Privacy walkback (vs initial brainstorm)

- **Mail mailbox name** — default OFF (e.g. "Client Acme Corp" is PII)
- **Calendar event title** — **NEVER captured** (only `in_meeting` boolean) — per architecture.md
- **WiFi SSID** — default OFF, opt-in only
- **Apple Notes** — title only, never body
- **Music / Spotify track name** — captured (not PII)
- **Bluetooth device names** — opaque counter only ("device connected"), not device name (e.g. "Anna's AirPods" = PII)

## Privacy regression tests (mandatory)

- `CGEventTapNoContentLeakageTests` — tap callback never reads / stores `.characters` / `.keycode` / `.modifierFlags`; only counter increments
- `MailMailboxOptInTests` — verifies Mail mailbox event kind default OFF в ShareEventTypeKey
- `CalendarNoTitleCaptureTests` — verifies `CalendarCollector` never reads `EKEvent.title`
- `WiFiSSIDDefaultOffTests` — verifies SSID change event default OFF
- `BluetoothNameOpaqueTests` — verifies Bluetooth events store opaque device counter, not device name

## Schema changes

- **M015**: New table `intensity_aggregates(minute_bucket_ms INTEGER PRIMARY KEY, keystrokes INTEGER, mouse_moves INTEGER, app_switches INTEGER, foreground_app TEXT)`. Hour rollup computed via Derived Insights Engine (SQL aggregation, no separate table).
- All other Track 4 signals → standard `events` table с additive payload kinds.

## Permissions UX

- **Onboarding additions:** EventKit (S1), Focus (S1) — стандартные modal prompts с clear copy ("Leaf reads calendar availability only — never event titles or attendees").
- **Settings → Local Apps** (new screen): per-app AppleScript opt-in toggle + permission state badge (granted / denied / not-requested / unavailable).
- **Settings → Privacy** (extend existing): master toggles для intensity counters (CGEventTap), clipboard, WiFi.
- **No batch AS prompt spam** — on-demand activation only.

## Acceptance criteria (per sub-phase)

- **S1:** All 4 catch-up collectors emit events на real session, EventKit + Focus Onboarding prompts work, graceful denial behavior (no crash, no spam), `in_meeting` boolean correctly toggles, `CalendarNoTitleCaptureTests` pass.
- **S2:** AppleScript invocation works для ~10 apps на собственной системе, per-app opt-in toggle + state badge accurate, denial doesn't crash, 24h denial cache prevents spam re-prompts, Mail opt-in default OFF respected.
- **S3:** All system observers emit events, `CGEventTapNoContentLeakageTests` pass, intensity counters correctly bucketed per minute, ScreenshotWatcher detects `~/Desktop` screenshot files (en + ru locale tested), WiFi SSID default OFF respected.
- **S4:** Registry expanded ~110-115 entries, FTS dispatcher extended для new title-bearing kinds, all events visible (raw mode) в Activity tab.

## Dependencies

- Track 2 D4 substrate — landed ✅
- Track 5 UI-A (shell redesign) — useful для contextual icons + filter chips но **not blocking** S4 ships raw event surfacing на existing Activity tab.
- LeafCorePrivate package — для AppleScript script bodies (moat per CLAUDE.md pre-push rules)

## Open questions

- **OQ-1:** EventKit prompt phrasing — "Leaf wants to read calendar **availability only** — never event titles" — wording critical для high grant rate. A/B test wording после S1 ship?
- **OQ-2:** CGEventTap battery impact measurement — need в-track benchmark на собственном Mac (idle baseline vs S3-active). Если >2% baseline drain — consider sampling вместо full tap.
- **OQ-3:** AppleScript dictionary stability — JetBrains / Zoom dictionaries могут изменяться по версиям. Per-version compatibility test или graceful degrade if AS call fails?
- **OQ-4:** ScreenshotWatcher pattern — macOS allows user-configurable screenshot prefix. Locale-aware fallback (en / ru / de / fr / es / ja) — locale list pinned или dynamic?
- **OQ-5:** BluetoothCollector value — likely low signal (most users connect AirPods 1x daily). Skip from S3? **Recommendation:** skip, revisit if user feedback shows demand.
- **OQ-6:** AS bridge timeout — 1s default OK? Some Zoom AS calls могут take longer if Zoom busy. Per-app timeout config?
- **OQ-7:** Architecture.md drift — after S1 ship, update architecture.md / whitepaper to reflect that Calendar / Focus / lock observers actually exist now (currently architecture.md описывает их как existing).

## Risk

- **AppleScript permission denial rate:** TCC dialogs пугают пользователей. Mitigation — clear Settings UI с per-app explain "what Leaf reads" + skip-without-blocking + opt-in only при первом включении тоггла.
- **CGEventTap performance regression** под fast typing → callback frequency spikes. Mitigation — `.listenOnly` + counter-only + auto-restart on drop.
- **Architecture.md drift trust impact:** developers reading architecture.md думают что Calendar / Focus / lock already work. S1 fixes drift. Update doc post-S1.
- **Apple platform updates:** future macOS может изменить AS dictionaries или CGEventTap API. Mitigation — per-version compat test suite + graceful degrade.

## Phase decomposition order

S1 → S2 → S3 → S4. Sequential. Каждый ship'ается на feature branch + acceptance gate (manual smoke на собственной системе). Collective merge после S4. Whitepaper sync deferred до post-S4 collective merge.
