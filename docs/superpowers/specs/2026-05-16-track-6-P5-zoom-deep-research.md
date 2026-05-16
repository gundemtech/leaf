# Track-6 P5 — Zoom Deep — Stage 0 Deep Research

**Status:** Stage 0 research output. Companion to `docs/superpowers/specs/2026-05-15-track-6-existing-surface-depth-contract.md` and (forthcoming) `docs/superpowers/specs/2026-05-16-track-6-P5-zoom-deep.md`.
**Date:** 2026-05-16.
**Branch:** `feature/track-6-P5-zoom-deep` off `main` (P4 substrate lives in `track-6-integration`; this spec assumes integration-time co-presence).
**Purpose:** map the realistic ceiling of Zoom capture on macOS, decide mechanism mix, surface the design questions that must be answered before Stage 2 brainstorm.

---

## 0. Baseline — what Track-4 S2 already gives us

Before mapping the ceiling, anchor the floor. Read excerpts confirm Track-4 S2 already shipped a shallow Zoom collector. **P5 extends, does not replace.**

| File | What it provides |
|---|---|
| `LeafCore/OS/ZoomObservation.swift` | `meetingState: { notInMeeting, inMeeting, waitingRoom, screenSharing }` + `ownMeetingTopic: String?` (sub-field-opt-in gated). No timestamps, no participants, no password. |
| `LeafCore/OS/ZoomStateMachine.swift` | Holds `prev: ZoomObservation?`. Emits up to 2 events per tick: `zoom_meeting_state_changed` (always) + `zoom_meeting_name_observed` (only when `meetingTopicOptedIn==true`). Idempotent. No duration / start-ms / cold-start flag. |
| `LeafCorePrivate/Prod/Collectors/Apple/ProdZoomAdapter.swift` (moat) | AppleScript adapter against `us.zoom.xos`, `timeoutSec=3.0` (other adapters 1.0; comment: "Zoom's `is meeting` query can block under load"). Parses 2-element `NSAppleEventDescriptor` list → `ZoomObservation`. |
| `LeafCore/DB/Schema.swift` | `EventPayloadKeys.zoomMeetingName = "zoom_meeting_name"`; FTS column wired for `zoom_meeting_name_observed`. |
| `LeafCore/Share/ShareEventTypeRegistry.swift` | `case zoomMeetingStateChanged`, `case zoomMeetingNameObserved` — both `defaultEnabled: false` per ADR-020. |
| `LeafCore/Insights/ActivityFeedMapper.swift` (lines 524–529, `trackFourLocalOSKinds` whitelist line 446) | Renders state event as `"Zoom: <state>"`, name event as `"Zoom: <topic>"`. No secondary text. |
| `LeafCore/Insights/EventKindIcon.swift` (lines 31–32) | Both kinds → `video.circle`. |
| `LeafCore/Share/LocalAppsStore.swift` | `isEnabled("us.zoom.xos")` master + `isSubFieldOptedIn("us.zoom.xos", "ownMeetingTopic")` sub. Both default false. |
| `RelayBodyLeakageTests.swift` (lines 1591–1615) | 2 walkbacks: `testRelayDoesNotLeakZoomAttendees_S2` (sentinels `SECRET-ZOOM-ATTENDEES-LIST-S2`, `SECRET-ZOOM-PASSWORD-S2` on `zoom_meeting_state_changed`); `testRelayDoesNotLeakZoomTopic_S2` (`SECRET-ZOOM-NAME-PASSWORD-S2`, `SECRET-ZOOM-CHAT-S2` on `zoom_meeting_name_observed`). |
| `AppleAdapterFixtureTests.swift` (lines 115–125, 188–193) | `testZoomParseValidDescriptor` (list `["in_meeting", "Q1 Planning"]` → `(.inMeeting, "Q1 Planning")`). `testProdRegistryZoomHasOverrideTimeout` (3.0s). |

**Extension points the baseline leaves on the table:**

1. **No timestamps stored.** The state machine has no `meetingStartedMs`. Cannot compute duration.
2. **`waitingRoom` and `screenSharing` states defined but no separate event_kind.** They collapse into `zoom_meeting_state_changed`.
3. **No cold-start flag.** First observation that is `.inMeeting` emits the state event with no indication that the agent was already mid-meeting.
4. **No calendar linkage.** Even though Track-4 S1 has EventKit and (in `track-6-integration`) P4 has Google Calendar, the Zoom collector does not consult either at meeting-detect time.
5. **No L4 redaction for PMI titles.** `ownMeetingTopic` flows through unchanged. Zoom's Personal Meeting ID default topic format is `<First Name> <Last Name>'s Personal Meeting Room` — this leaks the meeting owner's legal name into payload + presence whenever the user enables the sub-field.

---

## 1. Official vendor surfaces

### 1.1 Zoom AppleScript dictionary — does not exist

**Verified across 6 independent sources.** `zoom.us.app` ships **no `aete`/`sdef`** resource; Script Editor → Open Dictionary returns nothing for `us.zoom.xos`. Apple Developer Forums thread 680512 opens with the prior-art admission: *"I know that zoom.us is not technically scriptable with Applescript…"*

**Implication for Track-4 S2's ProdZoomAdapter.** The adapter's AppleScript necessarily goes through `tell application "System Events" → tell process "zoom.us"` (AX UI-scripting) rather than `tell application "zoom.us"`. The 2-element descriptor list returned is constructed by the script from `application "zoom.us" is running` + window-title / menu-item probes, then packaged as `[meeting_state_string, meeting_topic_string]` for the parser. This means:

- **No new TCC prompt is required.** Automation (`NSAppleEventsUsageDescription` against `us.zoom.xos`) is not what we're using; we're using `System Events` + AX. Both are already in Leaf's Layer A baseline.
- **The "topic" string is harvested from menu/title, not from a Zoom AS object.** When Zoom's host setting *Always show meeting topic* is OFF (the default), the window title is the literal `"Zoom Meeting"` and the topic field will be empty. The S2 collector gracefully drops to `ownMeetingTopic = nil` and the name-observed event does not fire.

### 1.2 Zoom REST API v2 — PKCE-clean, but live-state path is structurally infeasible

Context7 (`/websites/developers_zoom_us`) confirms Zoom OAuth supports **PKCE for public clients without `client_secret`**. Quote: *"Use PKCE when you don't have a backend server for user authorization, such as on mobile devices. Zoom offers a separate public client ID in the authorization request that doesn't require an associated client secret."* Unlike the Slack distributed-app pain that forced the Cloudflare Worker at `oauth.gundem.tech`, Zoom is the simple case — direct PKCE loopback like Linear.

REST polling can give us:

- `GET /users/me/meetings?type=scheduled` — upcoming meetings (id / topic / start_time / duration / type / join_url).
- `GET /users/me/meetings?type=previous_meetings` — meetings the user actually participated in.
- `GET /past_meetings/{id}/participants` — per-meeting participant list.

Rate limits comfortable for 5-min polling: Free tier "medium" 2 req/s + 2000 req/day; we'd burn ~144 req/day. Free Basic accounts can OAuth and call these endpoints (verified by multiple devforum threads).

**However**, REST cannot give us real-time "am I in a meeting right now" state. The only real-time signals are webhooks:

- `user.presence_status_updated` (Available / Away / DND / In_Meeting / On_Phone_Call)
- `meeting.started` / `meeting.ended`

**Why webhooks fail for Leaf's customer mix:**

1. **A webhook needs a public HTTPS URL.** A desktop app does not have one. We would need a relay (a second Cloudflare Worker route, fan-out via WebSocket) — architecturally identical to the Slack OAuth relay.
2. **`meeting.started`/`meeting.ended` webhooks are account-scoped.** Per the devforum thread *"Webhook for a user joining meeting on another account"*: a user-managed OAuth app's webhook only sees events for users on the SAME Zoom account. Leaf's customers (devs across personal-free + scattered-employer accounts) cannot rely on this unless they are an org admin.
3. **Presence webhooks are documented-flaky.** Multiple devforum threads report inconsistent delivery and case-mismatch bugs.

**Conclusion.** REST API value is **post-hoc reconciliation only** (yesterday's meeting durations, scheduled meetings list). It does not improve live-state vs AppleScript. Adding it costs:

- A new OAuth surface + Settings → Connections row.
- 7+ new privacy walkbacks per response shape (PMI name regex on `topic`, attendee email/displayName/id strip on `participants`, password/join_url strip, settings strip).
- An ongoing token-refresh path.

**Recommendation: defer REST to P5.1** (hypothetical follow-up). Document as a possible future addition for Derived Insights "meeting hours per week" accuracy where the floor-derived duration misses meetings while Leaf was off.

---

## 2. Apple framework / WWDC surfaces

### 2.1 AX `kAXTitleChangedNotification` — Strong (effort M)

`AXObserver` on `AXUIElementCreateApplication(zoomPID)` + per-window registration on `kAXTitleChangedNotification` fires regardless of frontmost. This is the canonical way to catch title transitions while the user is in another app (the common case — start a meeting, switch back to Xcode). Pattern verified in `tmandry/AXSwift`, `koekeishiya/yabai`, `tekezo/AXTest`.

Gotchas:

- Title-changed fires on the `AXWindow`, not the `AXApplication`. Need to observe `kAXWindowCreatedNotification` first, register per-window.
- Zoom is Qt-based; title-changed sometimes double-fires on the same logical change. Dedupe at consumer.
- Cold-start: register listeners AND take a one-shot `AXUIElementCopyAttributeValue(kAXTitleAttribute)` snapshot at boot.

**TCC cost: zero** (AX is existing Layer A permission).

### 2.2 CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` — already in Track-4 S3

S3 collector already listens for the "mic is hot" signal. P5 can **read** this state (no new code) and use it as evidence in the meeting-state-detection composite.

### 2.3 CoreAudio `kAudioProcessPropertyPID` (macOS 14+) — Strong (effort M)

Sonoma added Audio Process objects that expose the PID of each process currently using audio. Filter PIDs → bundle IDs via `NSRunningApplication(processIdentifier:)` → match `us.zoom.xos`. **This is the strongest free, TCC-free, name-the-consumer signal** for "Zoom is recording audio."

Use as primary evidence: if mic is hot AND `kAudioProcessPropertyPID` names a Zoom PID → high-confidence "in Zoom meeting." Audio-only meetings still trigger.

### 2.4 EventKit predicate for calendar cross-link — Strong (effort S)

`EKEventStore.events(matching: predicateForEvents(withStart: now − 5min, end: now + 60min, calendars: nil))` returns currently-active or upcoming events. Each `EKEvent` exposes:

- `.title` (meeting topic — ADR-010 forbids storing; we use only for matching, not persistence)
- `.location` (often `https://us02web.zoom.us/j/<id>?pwd=...`)
- `.notes` (URL + passcode block from auto-scheduling)
- `.url` (when host attaches URL property)

EventKit is already in Layer A (`EKEventStore.requestFullAccessToEvents`, ~80% grant). **No new prompt.** This sidesteps P4's `conference_uri` privacy ban entirely — we never write the URL to a payload; we only pattern-match it locally at meeting-start to derive `linked_calendar_event_id` (anonymized hash).

EventKit covers **every** calendar source the user has on macOS: iCloud, Google (via macOS Calendar.app's ICS subscription or native CalDAV), Outlook, Fastmail, etc. **This means cross-link works even without P4 OAuth completing** (which is blocked on GCP verification 2–6 wk wall).

### 2.5 NSWorkspace process probes — Critical (effort S)

`NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "us.zoom.xos" }` is free, no TCC, instant. Pair with:

- `NSWorkspace.didLaunchApplicationNotification` filter `us.zoom.xos` → "Zoom available"
- `NSWorkspace.didTerminateApplicationNotification` symmetric

Bundle ID inventory: `us.zoom.xos` (primary), `us.zoom.ZoomAutoUpdater` (ignore), `us.zoom.airhost` (screen-share helper, ignore for meeting detection).

### 2.6 AVCaptureDevice camera-busy — Marginal (effort S)

`AVCaptureDevice.isInUseByAnotherApplication` is **iOS-only**. On macOS, no public API names the camera consumer. `isSuspended` / `isConnected` KVO can detect "something has the camera" but cannot attribute to Zoom. Audio-only meetings won't show it. **Defer to optional secondary signal**; not in P5 MVP.

### 2.7 `INFocusStatusCenter` — already in Track-4 S1, do not duplicate

S1 captures Focus mode enabled/disabled. macOS auto-Focus "Do Not Disturb While in Meeting" is user-configured; can't distinguish reason. No new code.

### 2.8 System extensions — confirmed out of scope per Track-6 contract §1

EndpointSecurity could see process + audio/camera grants kernel-side. Costs sysext install. Track-6 forbids. Correct call.

---

## 3. OSS recon

| Source | Capture mechanism | What we learn |
|---|---|---|
| **ActivityWatch** — `aw-watcher-zoom` does **not** exist; `aw-watcher-macos` is **deprecated** per repo README. Zoom shows only as a generic window-title row via `aw-watcher-window`. Forum thread *"Tracking Zoom runtime"* documents the AFK-classifier under-reporting problem (in-meeting time misclassified as away). | The OSS leader has no Zoom-specific solution. Real moat opportunity. |
| **SwiftBar-Zoom-Plugins** (nickjvturner) | 1s-polling AppleScript via `System Events` → mute / video / share state from menu-item existence. | Confirms menu-item-existence pattern works in production for 2022-2024 Zoom releases. |
| **robbiebyrd / "Am I in a Zoom meeting" gist** (canonical 20-line detector) | process check → AXMain window AXTitle equality to `"Zoom Meeting"` → boolean. | The reference pattern for ~5 yr of OSS Zoom-presence work. AXTitle for in-meeting is the literal string `"Zoom Meeting"`, no topic. |
| **ZoomCommander** (jppellet) | Deep AX walk into participant list (`outline 1 of scroll area 1 of splitter group 1 of window "Zoom Meeting"`) and Breakout Rooms window. | **Confirms the depth of state locally accessible — which is exactly the ADR-010-forbidden surface.** We must self-cap. |
| **damc-dev gist** | Iterates participant list, extracts `static text` of each row → participant names. | The canonical PII-leak pattern. ADR-010 explicitly forbids. Useful negative example for the privacy walkback test naming. |
| **tyhawkins gist** | Mute state via `exists menu item "Mute audio" of menu 1 of menu bar item "Meeting"`. | Inversion-logic pattern. Locale-fragile. |

**Duration computation pattern observed uniformly:** edge-trigger on AXTitle transitions. On `not-in-meeting → "Zoom Meeting"`: emit `meeting_started`. On reverse / process exit / window count drops to 0: emit `meeting_ended` and compute `duration = ended_at - started_at`. **No vendor-supplied "this meeting ended" event exists.**

OSS edge cases harvested:
- Zoom crash mid-call → window vanishes → spurious `meeting_ended`. If user rejoins, second meeting starts.
- User minimizes window → AXTitle still present → meeting stays active. Correct.
- User locks screen mid-call → window stays → no change. Correct.

---

## 4. TCC / sandbox audit

| Mechanism | New TCC prompt? | Hardened-sandbox refusal? | Locale failure mode? |
|---|---|---|---|
| `application "zoom.us" is running` (LaunchServices) | No — free | No | None — bundle-ID match, locale-free |
| `tell application "System Events" → tell process "zoom.us"` (AX UI-scripting) | No — uses existing AX permission | No | Yes — window title `"Zoom Meeting"`, menu item names `"Mute audio"` are English; non-EN locales break (e.g. DE `"Zoom-Meeting"`, JA `"Zoom ミーティング"`) |
| `AXObserver` + `kAXTitleChangedNotification` | No — existing AX | No | Same locale issue as above |
| `NSWorkspace.runningApplications` / launch+terminate notifications | No — free | No | Locale-free |
| CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` | No — Track-4 S3 already wired | No | Locale-free |
| CoreAudio `kAudioProcessPropertyPID` (macOS 14+) | No | No | Locale-free; macOS 14+ requirement is fine — Leaf platform floor is macOS 14 |
| `EKEventStore.predicateForEvents` | No — existing Calendar permission | No | URL regex on `zoom\.us` is locale-free; event title regex for PMI name should also be locale-free since the format is consistent: `<First> <Last>'s Personal Meeting Room` (English-Zoom-account default). Non-English Zoom accounts may localize. Document as best-effort. |
| `AVCaptureDevice.isSuspended` KVO | No — read-only, does NOT trigger camera prompt | No | Locale-free |

**Net new TCC prompts for P5: zero.** This is the clean Track-6 add the contract envisioned for "extending depth without new permission asks."

**Locale mitigation strategy:** maintain a per-locale string table in `LeafCorePrivate/Prod/Collectors/Apple/ZoomTitleLocales.swift` (moat). Floor heuristic when the table doesn't match: `application "zoom.us" is running` AND `AXTitle starts-with "Zoom"` AND `AXTitle not-equal "Zoom"|"Zoom Workplace"|"Join Meeting"|"Settings"`.

---

## 5. Cross-link substrate — Track-1 D2 `event_links` deep look

### 5.1 M013 table shape

```sql
CREATE TABLE event_links (
  from_event_id  INTEGER NOT NULL,    -- logical FK to events.id
  link_kind      TEXT NOT NULL,
  target_kind    TEXT NOT NULL,
  target_ref     TEXT NOT NULL,
  confidence     REAL NOT NULL,
  created_at_ms  INTEGER NOT NULL,
  PRIMARY KEY (from_event_id, link_kind, target_ref)
);
CREATE INDEX idx_event_links_target ON event_links(target_kind, target_ref);
```

`INSERT OR IGNORE` idempotency on the composite PK. Reverse-lookup index for "events linking to X."

### 5.2 Two precedents for "when to derive the link"

| Pattern | Example | Trigger |
|---|---|---|
| **Inline at emit time** (pure-function extractor) | `LinearIDExtractor` (regex on body) → called by `EventLinksStore.deriveLinks` inside `Database.writeEvent()` same transaction | Fast, deterministic, single-event resolution. Cardinality N-to-M within one event. |
| **Deferred detector on cursor** | `DetectorPipeline` (decision / open_question / blocker_pattern) reads from `events` table since `detector_offsets.cursor_event_id`. ModeClassifier skeleton (4.7.C) is types-only precedent for the same shape. | Cross-event joins, multi-record reads, slow/expensive logic. |

### 5.3 Zoom→Calendar cross-link feasibility

**Path A — inline via EventKit at meeting-start emit time:**

When P5 detects a meeting transition `notInMeeting → inMeeting` (state machine + coalescer), the collector immediately queries `EKEventStore.events(matching: predicateForEvents(withStart: now−15min, end: now+15min, calendars: nil))`. Iterate active EKEvents. For each, regex-match `zoom\.us/(j|s|wc|my)/(\d+)` against `.location`, `.notes`, `.url`. First match wins. Emit a `zoom_meeting_calendar_linked` event with payload:

```json
{
  "event_kind": "zoom_meeting_calendar_linked",
  "calendar_source": "eventkit",                 // future: "google_calendar" if P4 reconciliation lands
  "linked_calendar_event_id": "<sha256(EKEvent.eventIdentifier)[:16]>",
  "match_method": "url_regex_eventkit",
  "confidence": 0.95
}
```

Then `EventLinksStore.deriveLinks` writes:
- `link_kind="zoom_to_calendar_meeting"`, `target_kind="calendar_event"`, `target_ref=<sha256 hash>`, `confidence=0.95`.

**Privacy guarantees:** raw URL never enters payload (only the SHA256 of the EKEvent identifier — which is opaque already; the SHA256 is belt-and-suspenders). Calendar source bucketed to `eventkit | google_calendar | unknown`. No EKEvent title / location / notes / URL ever persisted.

**Path B — deferred detector against P4 events:**

After meeting-start, a `ZoomToGcalLinker` detector wakes on cursor advance, reads `google_calendar_event_observed` rows in the past 15 min, joins by time window + `conference_solution_type ∈ {other, hangoutsMeet}` + `conference_entry_point_type=video`. **Cannot URL-match because P4 forbids `conference_uri` in payload** (Stream C confirmed: "Cannot differentiate Zoom from Webex/Cisco/Jitsi"). Best confidence ~0.7 with timing match only.

**Recommendation: Path A.** Reasons:

1. **Higher confidence** (raw URL match vs P4's bucketed type heuristic).
2. **Not P4-dependent** — works today, doesn't wait for GCP verification gate.
3. **Wider coverage** — EventKit sees iCloud, Outlook, native CalDAV, Google-via-macOS-Calendar, not just Google-API.
4. **No double-counting** — P4 still emits its own `google_calendar_event_observed`; the cross-link sits next to both events without conflict.
5. **Same TCC posture** — EventKit already in Layer A baseline.

Path B would still be the contract's literal hint ("zoom_to_gcal_meeting") but **the contract is wrong on this point** — Path A is strictly better given P4's privacy walkback. Update link_kind name to `zoom_to_calendar_meeting` (calendar-source agnostic) and document the deviation in spec §12 decision log.

### 5.4 Where the linker lives

Per Path A:

- **In `LeafCorePrivate/Prod/Collectors/Zoom/ZoomCalendarLinker.swift`** (moat — has the EKEvent URL regex + SHA256 derivation). Public protocol in `LeafCore/OS/ZoomCalendarLinker.swift` (interface only).
- Called inline from `ZoomCollector.observe()` when the state machine emits `meeting_started`.
- `EventLinksStore.deriveLinks` is **not** the natural fit for Path A — it expects body-text extractors. Instead, the collector writes the link row directly via `EventLinksStore.insertLink(...)` (new method, or reuse existing `Database.writeEvent` path with a new `LinkDerivers.zoomCalendarMatcher` closure).

---

## 6. Ceiling-vs-effort matrix — recommended signals

ADR-010 filter applied: signals struck through are forbidden by privacy contract.

| Signal | Mechanism | Effort | Value tier | Notes |
|---|---|---|---|---|
| `zoom_meeting_started` | Coalescer transition `idle → active` from composite (AX title + audio PID + running) | S | **Critical** | Replaces today's "first observation of `inMeeting` state." Carries `started_at_ms` + `cold_start: bool` + `evidence_signals: [string]`. |
| `zoom_meeting_ended` | Coalescer transition `active → idle` | S | **Critical** | Carries `ended_at_ms`, `duration_seconds`, `evidence_signals`, `dropped_transitions_count` (per Track-4 S3 intensity precedent). |
| `zoom_meeting_calendar_linked` | EventKit predicate + URL regex at meeting-start time | S | **Critical** | Path A. Sub-event emitted once per meeting; not per tick. Writes `event_links` row. |
| `zoom_screen_sharing_started` / `_ended` | AX menu-item presence transition: `"Start Share"` vs `"Stop Share"` | S | **Strong** | Metadata only (no shared-content capture). Aligns with Track-6 P3's "tab is active" framing where state-of-presentation is fine. |
| `zoom_video_state_changed` | AX menu-item presence: `"Start Video"` vs `"Stop Video"` | S | **Marginal** | Useful for "camera-on share" derived insight. Skip if effort grows. |
| ~~`zoom_mic_state_changed`~~ | Track-4 S3 already captures `mic_state_changed` via CoreAudio | — | **Skip** | Already in S3. Don't duplicate. Cross-link via PID match in derived layer. |
| `zoom_cold_start_observed` (flag-on-`_started`) | Watcher boot mid-meeting | S | **Strong** | Boolean on `zoom_meeting_started` payload, not separate event_kind. Phase 4.6.B precedent. |
| `zoom_meeting_state_changed` (existing) | Track-4 S2 baseline | — | **Keep** | Already there. Floor signal stays. |
| `zoom_meeting_name_observed` (existing) | Track-4 S2 baseline | — | **Keep + harden** | Apply PMI regex L4 redaction before persisting (see §7 surfaced question c). |
| ~~`zoom_meeting_topic` raw from REST~~ | REST `/users/me/meetings` | M | **Skip** | Defer entire REST surface to P5.1 follow-up. |
| ~~`zoom_participant_count`~~ | AX outline-walk | S | **Forbid** | Even count is org-graph PII (team size hint). The walk loads names into address space which violates "don't capture you don't need." |
| ~~`zoom_participant_names`~~ | AX outline rows | S | **Forbid** | ADR-010 third-party PII. |
| ~~`zoom_chat_messages`~~ | AX text-area dive | M | **Forbid** | ADR-010 content. |
| ~~`zoom_recording_state`~~ | AX status indicator | S | **Forbid** | ADR-010: recording state is the most sensitive bit possible — leaking "boss is recording" damages trust. |

**Net delta for P5: 4 net-new event_kinds** (`zoom_meeting_started`, `zoom_meeting_ended`, `zoom_meeting_calendar_linked`, `zoom_screen_sharing_started`/`_ended` as paired), keeping the two existing ones. ShareEventTypeKey registry 152 baseline + 4 net new + 1 paired = **6 entries** if we count started/ended as separate registry rows. Final shape decided in Stage 2 brainstorm.

**Optional add if effort allows:** `zoom_video_state_changed` (1 more entry, S effort). Brainstorm decides.

This lands inside the contract's "P5 ~3 entries" estimate as 5–6, slightly over. Document deviation: contract assumed title-observed + duration + calendar-linked = 3, but separating started/ended improves Derived Insights joinability and matches Track-3 D3 / Track-4 S3 conventions.

---

## 7. Anti-pattern surface — fail-cases harvested

Concrete production fail modes with severity tag + mitigation:

1. **Window title localized (HIGH).** English-only `"Zoom Meeting"` regex breaks on non-EN locales. **Mitigation:** locale table in `LeafCorePrivate` (moat) + `startsWith "Zoom" AND not-in-idle-set` fallback heuristic.

2. **Personal Meeting Room title leaks owner full name (HIGH, ADR-010).** Format `<First> <Last>'s Personal Meeting Room`. Already enabled in baseline if user opts into `meetingTopicOptedIn`. **Mitigation:** before persisting `meeting_topic`, regex-strip `^(.+?)'s Personal Meeting Room$` → bucket `"<pmi_meeting>"` placeholder. Tested via new RelayBodyLeakageTests sentinel `LEAKED_SENTINEL_ZOOM_PMI_NAME_P5`. **Walkback applies to both existing `zoom_meeting_name_observed` and new `zoom_meeting_started` (which may carry topic if observed).**

3. **Cold-start race — agent starts mid-meeting (HIGH).** No `meeting_started` event, no real start_at. **Mitigation:** emit single `zoom_meeting_started` with `cold_start: true` and `started_at_ms = agent_boot_ts`. Derived Insights treats cold-start meetings as duration-floor-only.

4. **User in meeting from browser zoom.us/wc (HIGH).** zoom.us.app NOT running. **Mitigation:** delegate to Track-6 P3 browser allow-list (zoom.us domain). P5 documents this as a gap, not a regression. Web meetings have lower fidelity (no mute/video/share visibility).

5. **Coalescer flicker on screen-share / reconnect (HIGH).** Zoom UI redraws / Qt window recreation / brief audio drops trigger 1-3s state oscillations. **Mitigation:** debounce coalescer with `GRACE_START=5s`, `GRACE_END=30s`. Match Track-4 S3 intensity precedent. Track dropped transitions count → `dropped_transitions_count` field on `_ended`.

6. **"Zoom Webinar" vs "Zoom Meeting" simultaneous (MED).** User may attend a webinar while also being in a meeting. Different windows. **Mitigation:** track each via separate state instance; emit `meeting_kind: "meeting" | "webinar" | "breakout"` field on `_started`. Webinar is a future add — MVP can treat `Zoom Webinar` title as `meeting_kind=webinar` if matched.

7. **AX tree shape changes between Zoom releases (MED).** Deep AX paths (participant outline) historically broke. **Mitigation:** we do NOT depend on the deep tree. Only top-level AXTitle + Meeting-menu menu-item-existence. Both stable since 2019.

8. **TCC revocation mid-session (MED).** User toggles off Accessibility for Leaf. AX calls return nil silently. **Mitigation:** detect by `AXMain returns nil && application is running` → emit single `zoom_capture_degraded` event, fall back to process-running + audio-PID-only signal until next AX recheck (5 min).

9. **Reconnecting state (LOW).** Network drop, Zoom shows reconnect UI; window persists. **Mitigation:** treat as continuous meeting via GRACE_END=30s. If process disappears for >30s, emit `meeting_ended`.

10. **Multiple meetings same time → which is "current" (LOW).** Zoom server enforces one active meeting per client; joining a second drops you from the first. Webinar is the exception (#6). **Mitigation:** single `Zoom Meeting` window invariant; webinar separate.

11. **Cross-link race — Zoom event arrives 100ms–5s before P4 calendar event indexed (N/A for Path A).** Path A reads EventKit, which is synchronous local DB query, not async-via-API. **No race.** Path B would have this race; another reason to favor Path A.

12. **Track-1 D2 event_links dispatcher drift (MED).** Track-3 D3 cleaned 3 body-kind dispatcher mismatches; the substrate has historical bugs. **Mitigation:** P5 doesn't add to `EventsFullTextStore` dispatcher (no new body-text field — meeting_topic already there from S2). But the new `event_links` rows need a `DispatchCoverageTests #16` parity fence — confirm the new `link_kind` is registered and resolved consistently.

---

## 8. Surfaced phase-level questions for user

These are blocking gates before Stage 2 brainstorm. Each has a defensible default below; user can redirect.

### Question (a) — Cross-link architecture: collector-inline EventKit, or deferred detector against P4?

**Default recommendation: Path A — collector-inline EventKit.**

Reasoning summary:
- Path A reaches **0.95 confidence** via raw `zoom.us/(j|s|wc|my)/<id>` URL regex against `EKEvent.location`/`.notes`/`.url`.
- Path B caps at **~0.7 confidence** because P4 forbids `conference_uri` in payload — cannot URL-match, only time-window + `conference_solution_type=other` heuristic which doesn't distinguish Zoom from Webex/Jitsi.
- Path A is **independent of P4 acceptance gate** (blocked on GCP setup 2-6 wk). P5 ships without waiting.
- Path A covers **iCloud + Outlook + native CalDAV + Google-via-macOS-Calendar**, not just Google-API-direct.
- Same TCC posture (EventKit already in Layer A).

Trade-off: Path A means the cross-link is calendar-source-agnostic (`link_kind=zoom_to_calendar_meeting`), not `zoom_to_gcal_meeting` as the contract hinted at. Spec §12 decision log records the deviation.

Alternate path C — both — is also defensible if Path B is added later for "Google-only" intra-account meeting matching by participant email domain. **Skip C for P5; revisit Phase 4.9.**

### Question (b) — Zoom REST API: in scope for P5 or defer?

**Default recommendation: defer to P5.1 / Phase 4.9 follow-up.**

Reasoning:
- Live state path is infeasible (webhooks org-admin-scoped + flaky).
- Post-hoc value (yesterday's durations) doesn't move the needle for MVP — AppleScript-derived duration is "good enough" for the same-day in-Leaf-runtime case.
- Cost: OAuth surface + Settings → Connections row + 7+ privacy walkbacks per response shape + PMI regex on `topic` field + ongoing token refresh.
- Stream D rates the trade-off "small win for large surface area."

If user wants REST in P5: add as **Phase 4 of the implementation** (after meeting state + duration + calendar link land). Stretch scope.

### Question (c) — PMI title L4 redaction: regex-strip owner name in payload?

**Default recommendation: yes — strip and bucket.**

Reasoning:
- Format `<First> <Last>'s Personal Meeting Room` is consistent for Zoom-English-locale defaults.
- Already would leak today via existing `zoom_meeting_name_observed` whenever user opts into the sub-field.
- ADR-010 walkback test sentinel: `LEAKED_SENTINEL_ZOOM_PMI_NAME_P5` = `Dmitrii Demidov's Personal Meeting Room` injected at parser; assert not in output payload.
- Implementation: in `LeafCorePrivate/Prod/Collectors/Apple/ProdZoomAdapter.swift` parser, after extracting topic string, run `topic.range(of: #"^(.+?)'s Personal Meeting Room$"#, options: .regularExpression)`. If match → replace with `"<pmi_meeting>"` literal. Pass through otherwise.
- Non-English Zoom accounts may use localized PMI format; document as best-effort.

**Bonus walkback fields to add tests for** (regardless of Q-c answer):
- `attendees` (already covered by S2 test — extend to new event_kinds).
- `password` (extend).
- `chat_history` (already covered for `zoom_meeting_name_observed` — extend to `zoom_meeting_started/_ended`).
- `recording_state` (new).
- `participant_names` (new — defense-in-depth even though we don't capture them, the AX tree could theoretically be misused upstream).
- `screen_share_content` (new — likewise defense-in-depth).
- `meeting_join_url` (new — Path A reads it from EventKit but never persists; sentinel asserts).

= ~7 walkbacks × 4 new event_kinds = ~28 new assertions added to `RelayBodyLeakageTests`. Acceptable per Track-3 D2/D3 / Track-4 / P4 precedent.

---

## 9. Final ceiling recommendation

**Primary mechanism stack:**
1. **Composite state-machine** evidence-scored from {AX title transition, CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`, CoreAudio `kAudioProcessPropertyPID` (macOS 14+), NSWorkspace.runningApplications}.
2. **Debounce coalescer** with `GRACE_START=5s`, `GRACE_END=30s` (numbers are moat — substrate-only constants in `LeafCorePrivate`).
3. **EventKit predicate at meeting-start** for calendar cross-link (Path A).
4. **Existing Track-4 S2** `zoom_meeting_state_changed` + `zoom_meeting_name_observed` keep firing — they are the "narrow" floor view of the same data. Stage 2 brainstorm decides whether to demote them under `_started/_ended` or keep both.
5. **PMI regex L4 redaction** at parser boundary for `meeting_topic` in all event_kinds.

**Secondary (optional, Stage 2 brainstorm decides):**
- `zoom_screen_sharing_started`/`_ended` via AX menu-item presence.
- `zoom_video_state_changed` via AX menu-item presence.

**Explicitly out of P5 scope:**
- Zoom REST API (defer to P5.1 if Derived Insights needs accurate past-meeting list).
- Participant count / names / chat / recording state (ADR-010 forbids).
- Web-client `zoom.us/wc` meetings (delegated to Track-6 P3 browser allow-list).
- macOS<14 CoreAudio PID fallback (Leaf platform floor is macOS 14, so accept).

**Target shape:**
- **4 net-new event_kinds**: `zoom_meeting_started`, `zoom_meeting_ended`, `zoom_meeting_calendar_linked`, `zoom_screen_sharing_started`/`_ended`. ShareEventTypeKey registry +5 entries (5 visible kinds with started/ended as separate rows, calendar_linked as one row). 152 → **157** (lower bound; Stage 2 may revise +1 for video state).
- **0 new tables** unless brainstorm surfaces a need. Track-4 S2 baseline already has `zoom_meeting_state_changed` going to events; new kinds layer onto the same table. M013 `event_links` is reused for cross-link writes. **M025 stays reserved for P2 Xcode (do not consume here).**
- **1 new presence_state composite write** (`presence_state.zoom` row) — single-row per provider, currently_active boolean + started_at_ms + meeting_kind bucket + linked_calendar_event_id?. Field shape decided in Stage 2.
- **~28 new RelayBodyLeakageTests assertions** (7 sentinel families × 4 new kinds).
- **0 new TCC prompts** beyond existing Layer A baseline.
- **0 new MCP tools** per contract §4 (Track-6 generally does not add MCP tools).
- **Settings UI: extend existing Local Apps → Zoom row** with new sub-toggles for the new event_kinds + a meta-toggle for calendar cross-link.

**Lines added estimate (substrate-only, no moat counted):** ~600 LOC + tests. Symmetric in shape to Track-6 P3 browser state machines (~700 LOC including moat).

---

## 10. Surfaced gaps / risk register

| Risk | Severity | Mitigation in spec |
|---|---|---|
| Non-EN Zoom locale breaks title regex | MED | Locale string table (moat) + `startsWith "Zoom"` fallback heuristic. |
| Cold-start race | MED | `cold_start: true` flag on first `_started`. |
| Coalescer thresholds wrong for some users (e.g. very flaky network → meetings drop > 30s) | MED | Surface `dropped_transitions_count` on `_ended` so Derived Insights can detect chronic flakiness. |
| EventKit URL regex misses non-standard Zoom URLs (e.g. custom `<company>.zoom.us`) | LOW | Regex includes `[a-z0-9-]+\.zoom\.us` (subdomain wildcard). Tested. |
| AX tree shape change in future Zoom releases | LOW | Don't depend on deep tree. Only AXTitle + Meeting-menu items. Watch for breakage in P5.1 if it hits. |
| PMI name regex misses localized format | LOW | Document as best-effort; non-EN Zoom accounts likely localize. Walkback test covers EN format. |
| Web-client meetings invisible without Track-6 P3 zoom.us allow-list | LOW | Explicit gap in spec §X "Out of scope." |
| Cross-link confidence overstated for Path A (0.95) when URL regex hits but timing skewed | LOW | EventKit predicate uses now±15min window. False-positives < 1% in realistic scheduling. Track confidence as field on payload for tunability. |

---

## 11. Sources

**Vendor docs:**
- [Apple Developer Forums — Scripting Zoom App (thread 680512)](https://developer.apple.com/forums/thread/680512)
- [Zoom OAuth 2.0 docs](https://developers.zoom.us/docs/integrations/oauth/)
- [Zoom OAuth scopes overview](https://developers.zoom.us/docs/integrations/oauth-scopes-overview)
- [Zoom API rate limits](https://developers.zoom.us/docs/api/rate-limits/)
- [Zoom Meetings webhooks reference](https://developers.zoom.us/docs/api/meetings/events/)
- [Zoom Using webhooks](https://developers.zoom.us/docs/api/webhooks/)
- [Webhook for user joining meeting on another account (devforum)](https://devforum.zoom.us/t/webhook-for-a-user-joining-meeting-on-another-account/53363)
- [Receiving inconsistent presence_status values (devforum)](https://devforum.zoom.us/t/receiving-inconsistent-presence-status-values-in-user-presence-status-updated-webhook-events/18810)
- [Meeting Topic changes to PMR (devforum)](https://devforum.zoom.us/t/meeting-topic-changes-to-x-users-personal-meeting-room/26657)

**Apple framework:**
- [AXObserver — Apple Developer](https://developer.apple.com/documentation/applicationservices/axobserver)
- [AXObserverAddNotification — Apple Developer](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)
- [AudioObjectGetPropertyData — Apple Developer](https://developer.apple.com/documentation/coreaudio/1422524-audioobjectgetpropertydata?language=objc)
- [EKEventStore events(matching:) — Apple Developer](https://developer.apple.com/documentation/eventkit/ekeventstore/1507183-events)
- [EKEventStore.predicateForEvents(withStart:end:calendars:)](https://developer.apple.com/documentation/eventkit/ekeventstore/1507479-predicateforevents)
- [NSWorkspace.runningApplications — Apple Developer](https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications)
- [Detect if audio is playing on macOS — Apple Developer Forums](https://developer.apple.com/forums/thread/677873)
- [How to detect if microphone is in use — Apple Developer Forums](https://developer.apple.com/forums/thread/113702)
- [Bring Continuity Camera to your macOS app — WWDC22 session 10018](https://developer.apple.com/videos/play/wwdc2022/10018/)

**OSS reference patterns:**
- [robbiebyrd "Am I in a Zoom meeting" gist](https://gist.github.com/robbiebyrd/88aea1f394d4c48349132237a106484b)
- [tyhawkins Get Zoom Mute/Unmute Status gist](https://gist.github.com/tyhawkins/66d6f6ca8b3cb30c268df76d83020a64)
- [damc-dev ZoomScript participants gist](https://gist.github.com/damc-dev/7431045c93fcb569140f2d2ef8afd878)
- [SwiftBar-Zoom-Plugins (nickjvturner)](https://github.com/nickjvturner/SwiftBar-Zoom-Plugins)
- [ZoomCommander (jppellet)](https://github.com/jppellet/ZoomCommander/blob/main/ZoomScript.applescript)
- [ActivityWatch watchers documentation](https://docs.activitywatch.net/en/latest/watchers.html)
- [ActivityWatch forum — Tracking Zoom runtime](https://forum.activitywatch.net/t/tracking-zoom-runtime/1329)
- [tmandry/AXSwift Observer.swift](https://github.com/tmandry/AXSwift/blob/main/Sources/Observer.swift)
- [koekeishiya/yabai application.h](https://github.com/koekeishiya/yabai/blob/master/src/application.h)

**Internal baseline (Track-4 S2, Track-1 D2, Track-6 P4):**
- `Packages/LeafCore/Sources/LeafCore/OS/ZoomObservation.swift` (main)
- `Packages/LeafCore/Sources/LeafCore/OS/ZoomStateMachine.swift` (main)
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/Apple/ProdZoomAdapter.swift` (main, moat)
- `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M013_EventLinks.swift` (main)
- `Packages/LeafCore/Sources/LeafCore/DB/EventLinksStore.swift` (main)
- `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearIDExtractor.swift` (main)
- `Packages/LeafCore/Sources/LeafCore/Detection/DetectorPipeline.swift` (main)
- `docs/superpowers/specs/2026-05-16-track-6-P4-google-calendar.md` (track-6-integration)
- `Packages/LeafCore/Sources/LeafCore/Integrations/GoogleCalendar/GoogleCalendarEventMapper.swift` (track-6-integration)

---

**End Stage 0. Ready for user gate on §8 surfaced questions before proceeding to Stage 2 brainstorm.**
