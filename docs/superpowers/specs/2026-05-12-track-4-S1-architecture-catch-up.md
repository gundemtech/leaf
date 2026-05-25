# Track-4 S1 — Architecture Catch-up

**Date:** 2026-05-12
**Status:** Draft (brainstorm-approved via Track-4 design contract; implementation plan in this same session per user direction "иду в зал — спек и план оба сразу")
**Owner:** Alex
**Branch (off):** `feature/track-3-D4-cross-cutting` (tip — Track-3 D4 landed, all five Track-3 stack sub-phases committed locally, awaiting collective merge per Track-3 contract §13)
**Branch (new):** `feature/track-4-S1-architecture-catch-up`
**Contract:** `docs/superpowers/specs/2026-05-11-track-4-local-os-sweep-design.md` § "S1 — Architecture catch-up"

## Goal

Реализовать те Layer A коллекторы, которые `architecture.md` описывал как существующие, но фактически отсутствуют в коде. **Substrate-only** работа — никаких новых OAuth integrations, никаких внешних API, никаких таблиц данных. Чистый OS-наблюдательский слой, обещанный architecture.md, и архитектурно эквивалентный `IdleCollector` / `ActiveAppCollector` по сложности.

S1 — **первая sub-phase из четырёх в Track 4**. После S1 → S2 (AppleScript) → S3 (system observers + intensity) → S4 (substrate integration). Каждая шипится в свою feature branch, collective merge после S4 per Track-4 contract §"Phase decomposition order".

## Context

Recon (2026-05-11, source — Track-4 design contract §"Context") показал, что `architecture.md` обещал четыре Layer A источника, которых нет в коде:

| Promised in architecture.md | Source API | Status |
|---|---|---|
| `EventKit` calendar — `in_meeting` boolean | `EKEventStore.requestFullAccessToEvents` | ❌ Missing |
| `INFocusStatusCenter` — Focus mode toggle | Intents framework | ❌ Missing |
| `DistributedNotificationCenter` — sleep / wake / screen-lock | `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` + NSWorkspace | ❌ Missing |
| `NSWorkspace` active space changes | `NSWorkspace.activeSpaceDidChangeNotification` | ❌ Missing |

**Downstream consequences of these gaps:**

- **Calendar gap:** Track-1 D3 detectors lose meeting-context signal — `WhereStoppedDeriver` can't distinguish "user idle because in meeting" from "user idle because EOD". `linear_assigned_workload_pulse` baseline can't be annotated as "elevated stress during meeting density spikes".
- **Focus gap:** Same — Focus mode is the user's explicit "I'm in deep work" signal; not capturing it means Derived Insights Engine can't surface "deep focus blocks coincide with personal Focus mode" pattern.
- **System state gap:** Sleep/wake/lock-screen mark exact session boundaries. Currently `focusSessions` boundary is `idleThresholdSec` (300s) — close, but post-lid-close transition is detectable in seconds via `willSleepNotification`. Session boundaries are wider than they need to be.
- **Spaces gap:** Multi-Space users (~30% of dev population per Apple data) — currently invisible context-shift channel.

**S3 dependency:** Track-4 S3 (`CGEventTap` intensity counter) MUST subscribe to `SystemStateCollector` for enable/disable lifecycle (CGEventTap must drop while system locked/sleeping to honour ADR-010 "Won't-list" — no keystroke counters from a locked screen). So S1 ships `SystemStateCollector` first; S3 wires the dependency later.

## Scope

### In scope

1. **`CalendarCollector`** (LeafAgent process)
   - `EKEventStore.requestFullAccessToEvents` permission flow.
   - Polling tick (60s) + `EKEventStoreChanged` notification re-poll.
   - Per-tick decision: does there exist an `EKEvent` overlapping `now` (i.e. `startDate <= now && endDate > now`) AND `!isAllDay` AND `status != .canceled` AND `eventStore.calendars(for: .event).contains(event.calendar)` (i.e. not from a disabled / hidden calendar)?
   - Emit transitions only — `meeting_state_entered` / `meeting_state_exited` — when boolean flips.
   - **NEVER read** `EKEvent.title` / `.location` / `.attendees` / `.notes` / `.url` / `.organizer` / `.calendar.title`. Compile-time guarantee via boundary type `MeetingObservation { isInMeeting: Bool }` — see §"Architecture — Boundary types".

2. **`FocusModeCollector`** (LeafAgent process)
   - `INFocusStatusCenter.default.requestAuthorization` permission flow.
   - Polling tick (60s) — `INFocusStatusCenter.default.focusStatus.isFocused: Bool?`.
   - Emit transitions only — `focus_mode_enabled` / `focus_mode_disabled` — when boolean flips.
   - Mode NAME not captured (macOS public API не exposes — `INFocusStatus.isFocused` only). Boolean is enough per Track-4 contract §"S1" ("optionally `focus_mode_changed` (mode name if available)" — N/A on macOS public surface). No `focus_mode_changed` event emitted.

3. **`SystemStateCollector`** (LeafAgent process)
   - `DistributedNotificationCenter.default()` subscribers for `"com.apple.screenIsLocked"` + `"com.apple.screenIsUnlocked"` (no permission required).
   - `NSWorkspace.shared.notificationCenter` subscribers for `willSleepNotification` + `didWakeNotification` (no permission required).
   - Emit on each transition — `system_locked` / `system_unlocked` / `system_slept` / `system_woke`. No de-bounce — these are inherently rare + atomic.
   - Exposes `var isLocked: Bool` and `var isSleeping: Bool` (read-only, MainActor-isolated) — S3 `CGEventTap` consumer subscribes via injected closure.

4. **`SpacesCollector`** (LeafAgent process)
   - `NSWorkspace.shared.notificationCenter` subscriber for `activeSpaceDidChangeNotification`.
   - Emit `space_switched` — payload carries **only** `{event_kind: "space_switched"}`. **NO** space identifier / name capture — `NSWorkspace.activeSpace` API exists but exposes only opaque integers, AND we deliberately drop them (decision per Track-4 contract §"S1": "workspace identifier as opaque counter, no space name capture"). Coalesce window — drop emissions within 2s of the previous (matches `fsEventsCoalesceWindowSec` pattern; rapid Mission-Control gesture sweeps would otherwise produce noise).

5. **Schema / wiring**
   - Add 9 new `ShareEventTypeKey` cases (Calendar 2 + Focus 2 + System 4 + Spaces 1) — all `defaultEnabled: false` per ADR-020 (capture-everything locally, share-selectively).
   - `AgentLifetime` gains 4 new slots (`calendarCollector` / `focusModeCollector` / `systemStateCollector` / `spacesCollector`).
   - `AgentThresholds` gains 2 new fields — `calendarPollIntervalSec` (default 60) + `focusModePollIntervalSec` (default 60). System / Spaces are notification-driven, no interval needed.
   - `Agent.main()` constructs all 4 (gated only by permission availability for Calendar + Focus — both gracefully no-op if permission denied; system / spaces always start).
   - Shutdown chain: spaces / system (no async cleanup, just observer removal) → focusMode → calendar (cancel polling Task + remove observer) before `writer.stop()`.

6. **Onboarding extension** (main Leaf app)
   - Insert new `OnboardingStep.observers` between `.fda` and `.team`.
   - Single step with two grant CTAs (Calendar + Focus) + per-CTA status indicator + "Skip for now" exit. Mirrors `axStep` / `fdaStep` shape (`LeafButton.primary` "Grant" → `LeafButton.ghost` "Skip for now" — pure substrate reuse, no new tokens).
   - `PermissionsService` gains `calendarGranted: Bool` + `focusGranted: Bool` observed properties + `triggerCalendarPrompt()` + `triggerFocusPrompt()` + `openCalendarSettings()` + `openFocusSettings()` (open System Settings → Privacy → Calendars / Focus respectively via `x-apple.systempreferences:` deep links).

7. **LeafAgent Info.plist** (new file)
   - LeafAgent currently has NO `INFOPLIST_FILE` build setting (confirmed via `grep INFOPLIST Leaf.xcodeproj/project.pbxproj`). EventKit + INFocusStatusCenter calls would crash on TCC violation without usage description strings embedded in the binary.
   - Create `LeafAgent/Info.plist` with `NSCalendarsFullAccessUsageDescription` + `NSFocusStatusUsageDescription` + minimal CFBundle keys (Identifier, Version, ShortVersionString from build vars). Add `INFOPLIST_FILE = LeafAgent/Info.plist` + `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` to LeafAgent Debug + Release build configs.
   - Usage description copy per Track-4 contract §"Risk → AppleScript permission denial" wording discipline:
     - Calendar: `"Leaf reads only whether you're currently in a meeting — never event titles, attendees, or location."`
     - Focus: `"Leaf reads only whether your Focus mode is on or off."`

### Out of scope (later phases or won't-list)

- **AppleScript / per-app introspection** — Track-4 S2.
- **CGEventTap / intensity / clipboard / audio / mic / display / VPN / WiFi / Bluetooth / FSEvents widening** — Track-4 S3.
- **FTS dispatcher / iconography / `share_event_types` runtime persistence / Activity tab title indexing** — Track-4 S4 (substrate integration).
- **Calendar event TITLE / location / attendees / notes capture** — ADR-010 won't-list, never. Boundary type `MeetingObservation` enforces compile-time.
- **`focus_mode_changed` with mode name** — macOS public API doesn't expose mode names (`INFocusStatus.isFocused: Bool?` only). Boolean is sufficient — emitted as `_enabled` / `_disabled`. Re-evaluate when Apple opens up the API in some future macOS.
- **Detection / linking against meeting-context** — Track-1 D3 detectors don't currently use meeting state; consuming the new signal is left for a future phase. S1 just ships capture.
- **Activity tab iconography** — Track-4 S4. S1 events are visible in raw-event mode (Activity tab existing surface) without per-kind icons.

## Architecture

### Boundary types — minimum-information capture

| Type | Module | Fields | Purpose |
|---|---|---|---|
| `MeetingObservation` | LeafCore | `isInMeeting: Bool` only | Translates EKEvent at the OS boundary; carries zero PII. Compile-time guarantee that the rest of the code-base can't accidentally access title/location/attendees. |
| `FocusObservation` | LeafCore | `isFocused: Bool` only | Same shape; INFocusStatus boundary. |

The OS-boundary code (in `LeafAgent/Collectors/CalendarCollector.swift`) reads only `event.startDate` / `event.endDate` / `event.isAllDay` / `event.status` from each `EKEvent` and produces a `MeetingObservation`. The transition-detection logic (in LeafCore for testability) consumes only the `Bool`. The collector code is the unique site where `EKEvent.*` properties can be touched — privacy regression test (§"Privacy walkbacks") asserts that `EKEvent.title` / `.location` / `.attendees` / `.notes` / `.url` / `.organizer` never appear in the collector source file.

### State machines — testable in LeafCore

| Type | Module | Inputs | Outputs |
|---|---|---|---|
| `MeetingStateMachine` | `Packages/LeafCore/Sources/LeafCore/OS/MeetingStateMachine.swift` | `observe(_:MeetingObservation, nowMs:)` | `Transition?` enum `.entered` / `.exited` / `nil` |
| `FocusStateMachine` | `Packages/LeafCore/Sources/LeafCore/OS/FocusStateMachine.swift` | `observe(_:FocusObservation, nowMs:)` | `Transition?` enum `.enabled` / `.disabled` / `nil` |
| `SpaceTransitionCoalescer` | `Packages/LeafCore/Sources/LeafCore/OS/SpaceTransitionCoalescer.swift` | `observe(nowMs:)` | `Bool` (emit or drop, drop if `nowMs - lastEmitMs < coalesceWindowMs`) |

`SystemStateCollector` has no state-machine analogue — each OS notification maps 1:1 to an event emission (no de-bounce needed). The collector itself is the test surface (subscribers wired correctly, observer removal on stop, no event duplication on rapid notification bursts — `XCTNotificationExpectation` pattern via injectable `NotificationCenter`).

### Collector lifecycle pattern

Mirror `IdleCollector` (LeafAgent) — fire-and-forget `Task` polling loop for Calendar + Focus; pure `addObserver` for SystemState + Spaces (no Task needed since callbacks are notification-driven). All four `start()` / `stop()` symmetric. `@unchecked Sendable` justified by single-thread access from MainActor (NSWorkspace observers + AppKit notification posting both main-queue).

### Permission-denied graceful path

| Collector | Denied behavior |
|---|---|
| CalendarCollector | `start()` invokes `requestFullAccessToEvents`; if status returns `.denied` / `.restricted` / `.writeOnly` / `.fullAccess` is false, collector logs once + stays running (no-op tick — polling skipped, observer NOT installed, zero events emitted). Re-request on Agent restart (TCC may have flipped). |
| FocusModeCollector | `INFocusStatusCenter.default.authorizationStatus == .authorized` check; if not, log once + stay running no-op. Mirror Calendar. |
| SystemStateCollector | No permission needed. |
| SpacesCollector | No permission needed. |

Critically: a collector "running no-op" still exists in `AgentLifetime` slots — shutdown signal handlers iterate `AgentLifetime.*` and call `stop()` defensively. No nil-handling branches in the shutdown chain.

### Event payload shapes

All S1 events use `SignalType.context`. Payload — minimal:

```
{
    "event_kind": "<kind>",
    "state": "<state>"      // only for meeting_state_entered/_exited and focus_mode_enabled/_disabled
}
```

Concretely:
- `meeting_state_entered` — `{event_kind: "meeting_state_entered", state: "in_meeting"}`
- `meeting_state_exited` — `{event_kind: "meeting_state_exited", state: "not_in_meeting"}`
- `focus_mode_enabled` — `{event_kind: "focus_mode_enabled", state: "focused"}`
- `focus_mode_disabled` — `{event_kind: "focus_mode_disabled", state: "not_focused"}`
- `system_locked` — `{event_kind: "system_locked"}`
- `system_unlocked` — `{event_kind: "system_unlocked"}`
- `system_slept` — `{event_kind: "system_slept"}`
- `system_woke` — `{event_kind: "system_woke"}`
- `space_switched` — `{event_kind: "space_switched"}`

No new `EventPayloadKeys` constants needed — `event_kind` + `state` are existing canonical keys (used by every collector since Phase 4.4).

### File touches

| File | Change |
|---|---|
| `Packages/LeafCore/Sources/LeafCore/OS/MeetingObservation.swift` | New value type (`public struct`, single `Bool` field). |
| `Packages/LeafCore/Sources/LeafCore/OS/FocusObservation.swift` | New value type. |
| `Packages/LeafCore/Sources/LeafCore/OS/MeetingStateMachine.swift` | New state machine — `enum Transition { case entered, exited }`, `mutating func observe(_:MeetingObservation, nowMs:Int64) -> Transition?`. |
| `Packages/LeafCore/Sources/LeafCore/OS/FocusStateMachine.swift` | New state machine — mirror of Meeting. |
| `Packages/LeafCore/Sources/LeafCore/OS/SpaceTransitionCoalescer.swift` | New — `mutating func observe(nowMs:Int64) -> Bool` (true = emit, false = drop). |
| `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` | +9 enum cases + 9 default OFF entries in `ShareEventTypeDefaults.all`. |
| `Packages/LeafCore/Sources/LeafCore/Agent/AgentThresholds.swift` | +2 fields (`calendarPollIntervalSec`, `focusModePollIntervalSec`), defaults 60. Mirror in `weakDefaults`. |
| `LeafAgent/Collectors/CalendarCollector.swift` | New collector — EKEventStore boundary + `MeetingStateMachine` integration + EWritcheduler tick. |
| `LeafAgent/Collectors/FocusModeCollector.swift` | New collector — INFocusStatusCenter boundary + `FocusStateMachine` integration + scheduler tick. |
| `LeafAgent/Collectors/SystemStateCollector.swift` | New collector — DistributedNotificationCenter + NSWorkspace notification observers. Exposes `isLocked` / `isSleeping` read-only state for future S3 consumer. |
| `LeafAgent/Collectors/SpacesCollector.swift` | New collector — NSWorkspace.activeSpaceDidChangeNotification observer + SpaceTransitionCoalescer integration. |
| `LeafAgent/Agent.swift` | Construct + wire all 4 collectors after existing Idle/ActiveApp/etc. construction; start/stop blocks extended; `AgentLifetime` extended +4 slots. |
| `LeafAgent/Info.plist` | New — `NSCalendarsFullAccessUsageDescription` + `NSFocusStatusUsageDescription` + minimal `CFBundle*` keys. |
| `Leaf.xcodeproj/project.pbxproj` | LeafAgent target — add `INFOPLIST_FILE = LeafAgent/Info.plist` + `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` for both Debug + Release. |
| `Leaf/Models/PermissionsService.swift` | +4 props (`calendarGranted` + `focusGranted` + transient state) + 4 methods (`triggerCalendarPrompt` / `triggerFocusPrompt` / `openCalendarSettings` / `openFocusSettings`). |
| `Leaf/Views/OnboardingView.swift` | Add `case observers` к `OnboardingStep` between `.fda` and `.team`. New `observersStep` view with two grant CTAs + status indicators. Wire step ordering in `OnboardingStep.allCases` discipline (raw values + nav). |
| `Packages/LeafCore/Tests/LeafCoreTests/MeetingStateMachineTests.swift` | New — transition coverage (5 fixtures). |
| `Packages/LeafCore/Tests/LeafCoreTests/FocusStateMachineTests.swift` | New — transition coverage (5 fixtures). |
| `Packages/LeafCore/Tests/LeafCoreTests/SpaceTransitionCoalescerTests.swift` | New — coalesce window logic (4 fixtures). |
| `Packages/LeafCore/Tests/LeafCoreTests/ShareEventTypeRegistryS1Tests.swift` | New — 9 enum cases registered, default OFF, total registry size 116 + 9 = 125. |
| `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` | +4 walkbacks — fake meeting title / focus mode name / space identifier / system-state arbitrary string never reach `presence_state.state_json`. |
| `.claude/shared/current-state.md` | Closing note for Track-4 S1 + Track-4 stack status. |

No schema migration. No new SQLCipher tables. No new payload keys. No moat (`LeafCorePrivate`) changes. No new event_kinds touching detection pipelines (DetectorPipeline + EventLinksStore body-kind dispatchers untouched — S1 emits no body-bearing events).

## Permissions UX

### Onboarding flow

Current: `welcome → ax → fda → team → done`.
After S1: `welcome → ax → fda → observers → team → done`.

`observersStep` layout (mirroring `axStep` / `fdaStep`):

```
Title: "Calendar & Focus"
Body: "Lets Leaf see when you're in a meeting or in Focus mode — never event titles, attendees, or Focus mode names."

[Grant Calendar]   Granted ✓ / Waiting…
[Grant Focus]      Granted ✓ / Waiting…

                                    [Skip for now]
```

Two CTAs trigger independent TCC prompts. Status indicators driven by `PermissionsService.calendarGranted` / `.focusGranted`. "Skip for now" advances to `.team` regardless of grant status (Track-4 contract §"S1": "graceful denial behavior — no crash, no spam").

### Settings → Privacy (existing screen)

Current Privacy section already shows AX + FDA toggles + "Open System Settings" deep links. Extend with two new rows (Calendar + Focus) mirroring shape — read state from `PermissionsService.calendarGranted` / `.focusGranted`, CTA → `openCalendarSettings()` / `openFocusSettings()`.

Settings extension is **deferred** from S1 if Settings → Privacy section refactor is in flight (check current-state.md — Track-2 D4 retired old palette, Settings → Privacy is `PrivacySettingsSection.swift` per file scan). Per CLAUDE.md root rule "don't add features beyond what the task requires" — Onboarding is enough. Settings extension can land in S2 or S4 polish work.

**Decision (in scope for S1):** Onboarding only. Settings → Privacy extension deferred — opens TCC settings deep-link directly from a future Connections-style "Local Apps" sub-screen in S2.

### TCC entry per binary

Calendar + Focus TCC entries are scoped per bundle ID (`tech.gundem.leaf.agent`). They are **distinct** from main app TCC entries (`tech.gundem.leaf`). Onboarding requests permissions in MAIN APP first (user-facing UX). LeafAgent **also** needs the entitlement — because it's the binary that actually reads `EKEventStore` / `INFocusStatusCenter`. Two TCC prompts will fire: one from main app (Onboarding "Grant Calendar" → main app's bundle ID), one from agent first time it polls (agent bundle ID).

**Mitigation:** When user clicks "Grant Calendar" in Onboarding, main app calls `EKEventStore.requestFullAccessToEvents` against its own EventStore instance, surfacing the prompt under `tech.gundem.leaf`. Agent then on next launch hits `requestFullAccessToEvents` against its store — surfaces SECOND prompt under `tech.gundem.leaf.agent`. Each is one-time per binary; user grants both, then no more prompts. Same dual-prompt model as ATTension via AX prompt (`tech.gundem.leaf` AX granted in Onboarding; agent inherits via fork-from-launchd / shared TeamID — actually no, AX is also per-bundle). The dual-prompt UX is inevitable per macOS TCC architecture.

Onboarding copy explains briefly: "You'll be asked twice — once for Leaf, once for the background helper that does the actual reading. Both must be granted." Per Track-4 contract §"Risk → AppleScript permission denial rate" — wording discipline matters.

Alternative (deferred, see OQ-S1-5): EventKit reads from main app process only, write events into the DB from main app via shared `EventWriter` interface. Less elegant — requires two writer instances across processes touching the same WAL DB. Decision: dual-prompt UX simpler.

## Privacy walkbacks (mandatory)

Per Track-4 contract §"Privacy walkback" + ADR-010 §6:

1. **`CalendarNoTitleCaptureTests`** — Grep test (`grep -rn 'EKEvent\.\(title\|location\|attendees\|notes\|url\|organizer\)'` in `LeafAgent/Collectors/CalendarCollector.swift`) returns zero matches. Plus runtime test: simulate `MeetingStateMachine.observe(_:MeetingObservation(isInMeeting: true), nowMs:)` ten times; assert emitted RawEvent payload contains exactly `{event_kind, state}` and **NO** other keys.
2. **`FocusNoModeNameCaptureTests`** — Grep test on `FocusModeCollector.swift` — `INFocusStatus` only `isFocused: Bool?` accessed, no other property reads.
3. **`SpacesNoIdentifierCaptureTests`** — Grep test on `SpacesCollector.swift` — no read of `NSWorkspace.activeSpace` or any space identifier API.
4. **`RelayBodyLeakageTests` extension** — 4 new walkbacks: feed `RawEvent` for each S1 event_kind through `writeEventsOffsetAndPresence` with realistic adversarial payload (e.g., a payload with a fake `title` key containing "SECRET-MEETING-TITLE-MARKER"); assert `presence_state.state_json` does not contain the marker. Mirrors existing 30-walkback pattern in `RelayBodyLeakageTests`.

## Test plan

TDD sequential per CLAUDE.md "Одна phase = одна сессия" → Stage 5 ("write failing test → run → see fail → implement → run → see pass → commit, after every step all tests still pass"). Tests target:

| Layer | Module | Tests added |
|---|---|---|
| State machines | LeafCoreTests | MeetingStateMachine (5) + FocusStateMachine (5) + SpaceTransitionCoalescer (4) |
| Registry | LeafCoreTests | ShareEventTypeRegistryS1Tests (3 — enum cases registered, all default OFF, total size 125) |
| Privacy regression | LeafCoreTests | 4 new walkbacks in RelayBodyLeakageTests |
| Privacy source-grep | LeafCoreTests | 3 source-file grep tests (Calendar / Focus / Spaces no-PII read) |
| Permissions UX | n/a | Manual smoke (TCC modals visible, denial → graceful no-spam) |
| Collector wiring | n/a | Manual smoke (agent restart after grant, events appear in DB) |

### Test count delta

| | Count |
|---|---|
| Baseline (Track-3 D4 ship — `feature/track-3-D4-cross-cutting` tip) | 1691 |
| +State machines (Meeting 5 + Focus 5 + Spaces 4) | +14 |
| +Registry expansion tests | +3 |
| +Privacy regression (RelayBodyLeakage extension) | +4 |
| +Source-grep privacy tests (Calendar + Focus + Spaces) | +3 |
| **Target** | **~1715** |

Spec acceptance tolerance: ±5 tests. Higher if state-machine TDD discipline reveals edge cases (e.g., observation with same boolean twice in a row, observation across day boundary).

### Build verification

After every implementation step:
1. `swift test --package-path Packages/LeafCore` → all green
2. `just check-tokens` + `just check-tokens-self-test` → both PASS
3. `just build-all` → 5/5 xcodebuild schemes (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP) green

## Acceptance criteria

- **AC1:** All 1691 baseline SPM tests pass; **~1715 total** after S1 ship (1690 + 25 new ± 5 tolerance).
- **AC2:** 5/5 xcodebuild schemes green (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP).
- **AC3:** `just check-tokens` PASS + `just check-tokens-self-test` PASS.
- **AC4:** `ShareEventTypeKey.allCases.count == 125` (116 baseline + 9 new); `ShareEventTypeDefaults.all.count == 125`; every new key has `defaultEnabled == false`.
- **AC5:** Manual smoke on Author's Mac (Alex's):
  - Cold install LeafAgent + LeafApp → Onboarding shows new `observersStep`.
  - Grant Calendar in Onboarding → TCC prompt fires under `tech.gundem.leaf`. Click Allow.
  - Next agent boot → TCC prompt fires under `tech.gundem.leaf.agent`. Click Allow.
  - Schedule a fake Calendar event starting in 1 min. After event starts → DB row `events.payload_json` contains `meeting_state_entered` within `calendarPollIntervalSec` (60s default).
  - When event ends → DB row `meeting_state_exited` fires within 60s.
  - Turn Focus mode ON via Control Center → `focus_mode_enabled` event within 60s. OFF → `focus_mode_disabled` within 60s.
  - `caffeinate -t 1 && pmset displaysleepnow` (lock screen) → `system_slept` + `system_locked` rows in DB. Unlock → `system_unlocked` + `system_woke` rows.
  - Swipe across Spaces (Ctrl-Right) → `space_switched` row in DB within 2s.
- **AC6:** `RelayBodyLeakageTests` extension (4 new walkbacks) pass. `grep -rn 'EKEvent\.\(title\|location\|attendees\|notes\|url\|organizer\)' LeafAgent/Collectors/CalendarCollector.swift` returns zero matches.
- **AC7:** Source-file grep tests pass — Calendar / Focus / Spaces collectors don't access PII OS APIs.
- **AC8:** Denial path graceful — denying Calendar in Onboarding doesn't crash main app or agent; denial state persists across agent restart; agent emits zero `meeting_state_*` events while denied.
- **AC9:** LeafAgent binary has embedded Info.plist with both usage description keys — verified via `otool -P build/Debug/LeafAgent | grep -A 1 NSCalendarsFullAccessUsageDescription` (or `plutil -p` on the embedded plist).

## Risks

- **R1 (medium):** TCC dual-prompt UX (main app + agent both ask for Calendar / Focus). Mitigation — Onboarding copy ("You'll be asked twice…") + visual progress indicator that updates on agent's grant detection. Acceptable per the architecture; same constraint affects any LaunchAgent + main-app architecture on macOS.
- **R2 (low):** `EKEventStoreChanged` notification floods if user's calendar is heavily edited (e.g., Spotlight indexing). Mitigation — collector debounces the trigger via existing 60s polling tick (notification just resets the poll clock); rapid bursts collapse to one tick.
- **R3 (low):** macOS `INFocusStatusCenter` private surface — if Apple ever changes the API shape, our collector breaks. Mitigation — `if #available(macOS 12, *)` gate + graceful no-op fallback; baseline macOS 14 is project requirement so no version risk in MVP.
- **R4 (low):** `DistributedNotificationCenter` notification names — `"com.apple.screenIsLocked"` / `"com.apple.screenIsUnlocked"` are unstamped private names. Apple has been stable on these for >10 years. Acceptable; if break, screen-lock collector silently no-ops (no event emitted) without crash.
- **R5 (very low):** Embedded Info.plist via `CREATE_INFOPLIST_SECTION_IN_BINARY` might surprise Sparkle / notarization tooling. Mitigation — `just build-all` + manual signed release smoke pre-merge; LeafAgent is already signed + notarized, embedding plist is standard Mach-O `__TEXT.__info_plist` section.

## Dependencies

- Track-3 stack complete and tip-of-branch (D1 + linear-reconciliation + D2 + D3 + D4 all landed) — provides the baseline test count 1691 ✅
- No external API providers.
- No leaf-relay changes.
- LeafCorePrivate untouched.

S1 has **zero** dependencies on Track-3 acceptance gate or Track-3 collective merge — these are orthogonal substrate work surfaces. S1 can ship before, during, or after Track-3 ship without conflict.

## Open questions

- **OQ-S1-1 (calendar polling interval):** 60s default chosen as low-cost-low-latency balance. Test: meeting starts at 10:00 → emitted as late as 10:00:60. Acceptable for downstream consumers (Track-1 D3 detectors don't need sub-minute precision). Lower (30s) marginal value. Keep 60s.
- **OQ-S1-2 (all-day events):** Spec is clear — `event.isAllDay == false` filter applied. All-day events are typically OOO markers / birthdays / vacation — not "in a meeting right now" signal.
- **OQ-S1-3 (Spaces coalesce window):** 2s default — drops rapid Mission-Control sweep noise but catches user-intent switches (one swipe takes >300ms). Configurable via `AgentThresholds.spaceTransitionCoalesceWindowSec` if real-world data shows different need.
- **OQ-S1-4 (Focus mode name capture):** macOS public API does NOT expose mode names (`INFocusStatus.isFocused: Bool?` only — `.identifier` is iOS-only, not macOS). Boolean only. Re-evaluate if Apple opens API.
- **OQ-S1-5 (single-prompt UX via main-app-only EventKit access):** Architectural alternative — main app reads EventKit, writes events into shared DB via separate writer. Rejected — dual-writer cross-process invariants are heavier than dual-prompt UX cost. Plus agent must read Calendar for future S3 / detection consumers (e.g., "user is in meeting, suppress CGEventTap"). Dual-prompt is the simpler architecture.
- **OQ-S1-6 (signal_type assignment):** All S1 events → `SignalType.context` per architecture.md §"Типы сигналов" ("Context — почему — meeting state + Focus mode + sleep/wake"). Confirmed.
- **OQ-S1-7 (LeafAgent Info.plist landing risk):** Sparkle update flow signs the agent binary. Embedded Info.plist sits in `__TEXT.__info_plist` Mach-O section — read at runtime by TCC, untouched by codesign / notarytool. Risk-vetted via release.sh dry-run before merge.

## Workflow per CLAUDE.md "Одна phase = одна сессия"

Eight stages. S1 spec covers Stages 1-3; S1 plan (same session per user direction) covers Stage 4. Stages 5-8 happen in next session.

1. ✅ Discovery (Stage 1) — done: substrate read, contract read, similar-collector patterns confirmed
2. ✅ Brainstorm (Stage 2) — done: Track-4 design contract is brainstorm-approved per its header `Status: Draft (brainstorm-approved...)`; S1 inherits via §"Approach → S1" exhaustive enumeration
3. ✅ Spec write (Stage 3) — **this document**
4. ⏭ Plan (Stage 4) — **same session continuation** (per user direction "иду в зал — спек и план оба сразу"); file `docs/superpowers/plans/2026-05-12-track-4-S1-architecture-catch-up.md`
5. ⏭ Implementation (Stage 5) — TDD sequential per plan, **separate session**
6. ⏭ Independent review (Stage 6) — `superpowers:code-reviewer` subagent
7. ⏭ Verification (Stage 7) — `superpowers:verification-before-completion`
8. ⏭ Ship (Stage 8) — final commit `docs(shared): Phase Track-4 S1 landed — current-state update`. **NO push, NO merge** — Track-4 stack waits collective merge after S4 ship + acceptance gate per Track-4 contract §"Phase decomposition order".

## Post-S1 path

S1 lands as a substrate-only sub-phase. After ship:

1. **Track-4 S2 work starts in separate session** — AppleScript surface (~10 apps). Off `feature/track-4-S2-applescript`, baselined on S1 ship tip.
2. **No Track-4 acceptance gate yet** — gate fires after S4 per contract §"Acceptance criteria (per sub-phase)" matrix. S1 individual smoke validates S1 alone (per §"Acceptance criteria → S1").
3. **No whitepaper sync** — Track-4 contract §"Phase decomposition order" states whitepaper sync deferred until post-S4 collective merge. Architecture.md drift (it currently describes Calendar / Focus / lock observers as existing — they will actually exist after S1) gets reconciled then.
