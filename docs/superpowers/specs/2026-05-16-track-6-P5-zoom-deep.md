# Track-6 P5 — Zoom Deep — Design Spec

**Status:** Stage 3 spec — pending implementation.
**Date:** 2026-05-16.
**Branch:** `feature/track-6-P5-zoom-deep` off `main`.
**Sequential dep:** P4 (Google Calendar) — substrate live in `track-6-integration`. **Cross-link path A (EventKit inline) makes P5 independent of P4 acceptance gate.**
**Companion:** `docs/superpowers/specs/2026-05-16-track-6-P5-zoom-deep-research.md` (Stage 0 — read first).
**Contract:** `docs/superpowers/specs/2026-05-15-track-6-existing-surface-depth-contract.md`.

---

## 1. Goal & non-goals

### 1.1 Goal

Bring Zoom capture from Track-4 S2's binary `in_meeting` boolean to depth-parity surface comparable to other Track-6 phases: durable session timestamps, calendar cross-link, ADR-010-compliant payloads, **0 new TCC prompts**, **0 new tables**, **3 net-new event_kinds**, **5 new substrate tests + ~24 walkback assertions**.

P5 deliverables:

1. **Duration tracking.** Emit `zoom_meeting_started` / `zoom_meeting_ended` event pair with timestamps + cold-start flag + dropped-transitions counter. Replaces today's "1 state event per transition with no aggregation."
2. **Calendar cross-link.** When a Zoom meeting starts and EventKit reports an active event with a Zoom URL in `.location`/`.notes`/`.url`, emit `zoom_meeting_calendar_linked` and write a `zoom_to_calendar_meeting` row to `event_links`.
3. **PMI redaction.** Strip the owner's legal name from any `<First> <Last>'s Personal Meeting Room` topic at the parser boundary, before `ZoomObservation` exists.
4. **`presence_state.zoom` composite row.** Single-row materialized view of "am I currently in a Zoom meeting" with linked-calendar reference.
5. **Coalescer.** Debounce transitions with GRACE_START=5s and GRACE_END=30s (moat values) to suppress UI flicker, reconnect drops, screen-share window reparenting.

### 1.2 Out of scope

| Out of P5 | Reason | Where |
|---|---|---|
| Zoom REST API (OAuth + polling) | Webhook live-state path infeasible for individual-dev customers (org-admin-scoped, flaky); post-hoc value insufficient. | P5.1 follow-up if Derived Insights needs accurate past-meeting list. |
| Screen-share started/ended event_kinds | Marginal value per research §6; AS complexity not justified for MVP. | P5.1. |
| Video state changed | Marginal per research; only adds "camera-on share" derived insight. | P5.1. |
| CoreAudio `kAudioProcessPropertyPID` triangulation | Adds new Apple API surface. AS-reported `is meeting` boolean is already high-confidence. Triangulation reserves itself for "exotic" mismatch case. | P5.1. |
| AXObserver `kAXTitleChangedNotification` | 30s polling already short enough for meeting-state. AXObserver adds C-pointer cleanup surface. | P5.1 if live-presence becomes a UX requirement. |
| Web-client meetings (`zoom.us/wc` in browser) | zoom.us.app NOT running. Delegate to Track-6 P3 browser allow-list (`zoom.us` domain). | Track-6 P3 (separate phase). |
| Participant list / count | ADR-010 — third-party PII + org-graph leak. | Permanent won't-list. |
| Chat messages / recording state | ADR-010 forbidden. | Permanent won't-list. |

---

## 2. Architecture

### 2.1 Layer diagram

```
                   ┌────────────────────────────────┐
                   │  ProdZoomAdapter (moat)        │
                   │  ─ AppleScript tickScript      │
                   │  ─ parse() with PMI redaction  │ ← ProdZoomMeetingTopicRedactor (moat)
                   │  ─ observe() fan-out:          │
                   └──┬────────┬────────┬───────────┘
                      │        │        │
              ZoomObservation  │        │
                      │        │        │
                      ▼        ▼        ▼
        ┌─────────────────┐  ┌──────────────────────────┐
        │ ZoomStateMachine│  │ ZoomMeetingDurationTracker│ ← thresholds (moat),
        │ (existing S2)   │  │ (new, public, pure)       │   calendarLinker (moat),
        │                 │  │                           │   redactor (moat-injected)
        │ emits:          │  │ emits:                    │
        │ _state_changed  │  │ _meeting_started          │
        │ _name_observed  │  │ _meeting_ended            │
        │                 │  │ _meeting_calendar_linked  │
        └────────┬────────┘  └──────────┬────────────────┘
                 │                      │
                 └──── RawEvents ───────┘
                          │
                          ▼
                ┌─────────────────────┐
                │ Database.writeEvent │ → triggers EventLinksStore.deriveLinks
                │                     │   on zoom_meeting_started + payload key
                │                     │   linked_calendar_event_id present
                └─────────┬───────────┘
                          │
                          ▼
                ┌─────────────────────────────┐
                │ event_links (M013):         │
                │  link_kind=                 │
                │   zoom_to_calendar_meeting  │
                │  target_kind=calendar_event │
                │  target_ref=<sha256[:16]>   │
                │  confidence=0.95            │
                └─────────────────────────────┘
                          
                ┌─────────────────────────────┐
                │ presence_state row          │
                │  provider="zoom"            │
                │  state_json={               │
                │   meeting_active,           │
                │   meeting_started_at_ms?,   │
                │   cold_start?,              │
                │   linked_calendar_event_id?,│
                │   last_observed_at_ms       │
                │  }                          │
                └─────────────────────────────┘
```

### 2.2 Component responsibilities

| Component | Where | Responsibility |
|---|---|---|
| `ZoomObservation` (existing) | `LeafCore/OS/ZoomObservation.swift` | Value type. No changes. |
| `ZoomStateMachine` (existing) | `LeafCore/OS/ZoomStateMachine.swift` | Floor signals. No changes. Continues emitting `_state_changed` + `_name_observed`. |
| `ZoomMeetingDurationTracker` (new) | `LeafCore/OS/ZoomMeetingDurationTracker.swift` | Pure-Swift state machine. Coalescer + timestamps + cold-start + dropped-transitions + calendar-linker invocation. |
| `ZoomCalendarLinker` (new, protocol) | `LeafCore/OS/ZoomCalendarLinker.swift` | Interface only: `match(atMs: Int64) -> String?` returns SHA256 hash or nil. |
| `NoOpZoomCalendarLinker` (new) | `LeafCore/OS/ZoomCalendarLinker.swift` | Test/default impl: always nil. |
| `ZoomMeetingTopicRedactor` (new, protocol) | `LeafCore/OS/ZoomMeetingTopicRedactor.swift` | Interface only: `redact(_ raw: String) -> String`. |
| `IdentityZoomMeetingTopicRedactor` (new) | `LeafCore/OS/ZoomMeetingTopicRedactor.swift` | Test/default impl: pass-through. |
| `ProdZoomCalendarLinker` (new, moat) | `LeafCorePrivate/Prod/Collectors/Apple/ProdZoomCalendarLinker.swift` | EventKit predicate + URL regex + SHA256 derivation. Real implementation. |
| `ProdZoomMeetingTopicRedactor` (new, moat) | `LeafCorePrivate/Prod/Collectors/Apple/ProdZoomMeetingTopicRedactor.swift` | PMI regex + bucket replacement. Real implementation. |
| `ProdZoomDurationTrackerThresholds` (new, moat) | `LeafCorePrivate/Prod/Collectors/Apple/ProdZoomDurationTrackerThresholds.swift` | Production GRACE_START / GRACE_END constants. |
| `ProdZoomAdapter` (existing, extended) | `LeafCorePrivate/Prod/Collectors/Apple/ProdZoomAdapter.swift` | Wire redactor in parse(), tracker in observe(). |

### 2.3 Data flow per tick

Polling cadence remains **30s** (unchanged from S2). Per tick:

1. `AppleScriptAdapter` invokes `tickScript` → returns `[meeting_state_string, meeting_topic_string]` 2-element list.
2. `ProdZoomAdapter.parse(descriptorData:)`:
   - Decode 2-element list.
   - Apply `ProdZoomMeetingTopicRedactor.redact(rawTopic)`. If raw matches `^(.+?)'s Personal Meeting Room$` → bucket `"<pmi_meeting>"`. Otherwise pass-through.
   - Construct `ZoomObservation(meetingState:, ownMeetingTopic: redactedOrNil)`.
3. `ProdZoomAdapter.observe(observation:, nowMs:, localAppsStore:)`:
   - Call `stateMachineBox.observe(obs, nowMs:, topicOptedIn:)` → up to 2 baseline events.
   - Call `durationTrackerBox.observe(obs, nowMs:, calendarLinker:)` → up to 2 new events (`_started` or `_ended`, plus optional `_calendar_linked`).
   - Concatenate event lists.
4. Agent flush writes events via `Database.writeEvent` → triggers `EventLinksStore.deriveLinks` per-event.
5. Agent flush also calls `PresenceStateWriter.upsert(provider: .zoom, state: ...)` (composite row update once per tick).

### 2.4 Backward-compatibility invariants

- **Existing baseline events keep emitting unchanged.** `zoom_meeting_state_changed` and `zoom_meeting_name_observed` continue to fire on every transition as in S2.
- **PMI redaction is a strict tightening of existing privacy posture.** Pre-P5, a PMI-format topic would have flowed through to `zoom_meeting_name_observed` payload. Post-P5, it's bucketed before reaching either event. No new field is exposed; an existing field's content is narrowed.
- **`ZoomObservation` shape unchanged.** No new fields added; `ownMeetingTopic` is still optional `String?`.
- **`ZoomStateMachine` unchanged.** Existing tests pass without modification.
- **Settings → Local Apps → Zoom existing master toggle + `ownMeetingTopic` sub-toggle stay.** New sub-toggles added below them.

---

## 3. Event_kinds (3 net-new)

### 3.1 `zoom_meeting_started`

Emitted exactly once when the duration tracker transitions from `idle`/`pendingStart` to `active`.

Payload schema:

```json
{
  "source": "zoom",
  "event_kind": "zoom_meeting_started",
  "started_at_ms": 1715882400000,
  "cold_start": false,
  "linked_calendar_event_id": null
}
```

Fields:

| Field | Type | Notes |
|---|---|---|
| `event_kind` | string | Always `"zoom_meeting_started"`. |
| `source` | string | Always `"zoom"`. |
| `started_at_ms` | int64 | Epoch ms when meeting first detected. For cold-start (`prev==nil && meetingActive==true`), equals agent boot time (tick-1 `nowMs`). For warm-start, equals the `nowMs` of the tick that observed first `meetingActive=true` (one tick before the GRACE_START stabilization). |
| `cold_start` | bool | `true` if first observation post-boot was already `meetingActive=true`. Indicates the user was already in a meeting when Leaf Agent started — duration measured from boot, not actual meeting start. |
| `linked_calendar_event_id` | string \| null | SHA256(EKEvent.eventIdentifier)[:16] hex string when `ZoomCalendarLinker.match` returns a match. Null otherwise. Always present in shape (explicit null), so `EventLinksStore.deriveLinks` can short-circuit. |

**ADR-010 fields explicitly forbidden:** `attendees`, `password`, `chat_history`, `recording_state`, `participant_names`, `participant_count`, `screen_share_content`, `meeting_join_url`, `raw_pmi_name`, `meeting_topic` (gated already through state-machine `_name_observed`; not re-emitted on `_started`).

### 3.2 `zoom_meeting_ended`

Emitted exactly once when the duration tracker transitions from `active`/`pendingEnd` to `idle` via GRACE_END.

Payload schema:

```json
{
  "source": "zoom",
  "event_kind": "zoom_meeting_ended",
  "started_at_ms": 1715882400000,
  "ended_at_ms": 1715886000000,
  "duration_seconds": 3600,
  "cold_start_origin": false,
  "dropped_transitions_count": 0,
  "linked_calendar_event_id": null
}
```

Fields:

| Field | Type | Notes |
|---|---|---|
| `event_kind` | string | Always `"zoom_meeting_ended"`. |
| `source` | string | Always `"zoom"`. |
| `started_at_ms` | int64 | Equals the `started_at_ms` of the paired `_started` event. Carried for joinability. |
| `ended_at_ms` | int64 | Epoch ms when the `pendingEnd` state confirmed via GRACE_END. Equals the `nowMs` of the tick that observed first `!meetingActive`, NOT the GRACE_END stabilization tick. |
| `duration_seconds` | int64 | `(ended_at_ms - started_at_ms) / 1000`. |
| `cold_start_origin` | bool | True if the paired `_started` had `cold_start: true`. Allows Derived Insights to filter cold-start sessions when computing accurate-only stats. |
| `dropped_transitions_count` | int | Number of brief `!meetingActive → meetingActive` revert oscillations observed during `pendingEnd` state. Surfaced for chronic-flaky-network diagnosis. |
| `linked_calendar_event_id` | string \| null | Same value as paired `_started`. |

### 3.3 `zoom_meeting_calendar_linked`

Emitted **once per meeting session, concurrent with the `_started` event**, only when `ZoomCalendarLinker.match` returns non-nil. Standalone observability event so the chronological feed shows a discrete "linked to calendar" entry without needing UI logic to introspect `_started` payload.

Payload schema:

```json
{
  "source": "zoom",
  "event_kind": "zoom_meeting_calendar_linked",
  "started_at_ms": 1715882400000,
  "linked_calendar_event_id": "a3f7b2c1d4e5f6a7",
  "calendar_source": "eventkit",
  "match_method": "url_regex_eventkit",
  "confidence": 0.95
}
```

Fields:

| Field | Type | Notes |
|---|---|---|
| `event_kind` | string | Always `"zoom_meeting_calendar_linked"`. |
| `source` | string | Always `"zoom"`. |
| `started_at_ms` | int64 | Paired meeting's `started_at_ms`. |
| `linked_calendar_event_id` | string | SHA256(EKEvent.eventIdentifier) first 16 hex chars. Opaque target_ref. |
| `calendar_source` | string | Bucket: `"eventkit"` for MVP. `"google_calendar"` reserved for future P4 reconciliation. |
| `match_method` | string | Audit field: `"url_regex_eventkit"` for MVP. Future expansion if heuristic time-window matching is added: `"time_window_only"`. |
| `confidence` | float | 0.95 for URL-regex match. Future heuristic methods: lower values. |

**ADR-010 fields explicitly forbidden:** `calendar_event_title`, `calendar_event_location_raw`, `calendar_event_notes_raw`, `calendar_event_url_raw`, `attendees`, `organizer_email`, `organizer_name`.

---

## 4. ZoomMeetingDurationTracker — state machine

### 4.1 States

```swift
public enum DurationTrackerState: Sendable, Hashable {
    case idle
    case pendingStart(observedAt: Int64)
    case active(startedAt: Int64, coldStart: Bool, linkedCalEventID: String?)
    case pendingEnd(startedAt: Int64, observedAt: Int64, coldStart: Bool, linkedCalEventID: String?, droppedTransitions: Int)
}
```

### 4.2 `meetingActive` predicate

```swift
private static func isMeetingActive(_ state: ZoomMeetingState) -> Bool {
    switch state {
    case .notInMeeting: return false
    case .inMeeting, .waitingRoom, .screenSharing: return true
    }
}
```

Waiting room and screen-sharing count as "in meeting" — the user is engaged with the meeting; coalescer should not flip between them.

### 4.3 Transition table

Given previous state `S`, current observation `obs`, `nowMs`, the next state and emitted events:

| Previous state | `meetingActive(obs)` | Cold-start? | Next state | Emit |
|---|---|---|---|---|
| `idle` (prev==nil) | false | — | `idle` | — |
| `idle` (prev==nil) | true | YES | `active(startedAt: nowMs, coldStart: true, linkedCalEventID: linker.match(nowMs))` | `_started{cold_start:true}` + maybe `_calendar_linked` |
| `idle` (prev!=nil) | true | NO | `pendingStart(observedAt: nowMs)` | — |
| `idle` (prev!=nil) | false | — | `idle` | — |
| `pendingStart(t0)` | true | NO | If `nowMs - t0 >= GRACE_START_MS`: `active(startedAt: t0, coldStart: false, linkedCalEventID: linker.match(t0))` — emit `_started{cold_start:false}` + maybe `_calendar_linked`. Otherwise: `pendingStart(t0)` (re-affirmed, no change). | conditional |
| `pendingStart(_)` | false | — | `idle` (false alarm) | — |
| `active(t0, cs, link)` | true | — | `active(t0, cs, link)` (re-affirmed) | — |
| `active(t0, cs, link)` | false | — | `pendingEnd(startedAt: t0, observedAt: nowMs, coldStart: cs, linkedCalEventID: link, droppedTransitions: 0)` | — |
| `pendingEnd(t0, te0, cs, link, dropped)` | true | — | `active(t0, cs, link)` (revert). Increment dropped semantically inside state — held in transient counter, surfaced on next `_ended` emit. | — |
| `pendingEnd(t0, te0, cs, link, dropped)` | false | — | If `nowMs - te0 >= GRACE_END_MS`: `idle` — emit `_ended{started_at_ms:t0, ended_at_ms:te0, duration_seconds:(te0-t0)/1000, cold_start_origin:cs, dropped_transitions_count:dropped, linked_calendar_event_id:link}`. Otherwise: `pendingEnd(...)` (re-affirmed). | conditional |

**Cold-start semantics:** "cold-start" applies only to the FIRST tick where `prev == nil`. After that, `prev != nil` so subsequent first-time-meeting-active observations are normal `pendingStart` flow. There's no scenario where `cold_start: true` fires on a non-boot tick.

**Dropped-transitions counter:** held in `pendingEnd` state. On revert (`pendingEnd → active`), the counter is incremented and the next `pendingEnd` cycle inherits it. On commit (`pendingEnd → idle` via GRACE_END), the counter is reset (it's part of the emitted payload).

### 4.4 Threshold values (moat)

```swift
// LeafCorePrivate/Prod/Collectors/Apple/ProdZoomDurationTrackerThresholds.swift
public func prodZoomDurationTrackerThresholds() -> ZoomMeetingDurationTracker.Thresholds {
    .init(graceStartMs: 5_000, graceEndMs: 30_000)
}
```

Public testing default `.testing` uses 1ms / 1ms for fast unit tests:

```swift
// LeafCore/OS/ZoomMeetingDurationTracker.swift
public struct Thresholds: Sendable, Hashable {
    public let graceStartMs: Int64
    public let graceEndMs: Int64

    public static let testing = Self(graceStartMs: 1, graceEndMs: 1)
}
```

### 4.5 Calendar linker invocation

`ZoomMeetingDurationTracker.observe(...)` calls `calendarLinker.match(atMs: startedAtMs)` exactly **once per session** — at the `_started` emit moment. The result is stored in the `active` state and re-used on the `_ended` emit. No per-tick linker invocations.

For cold-start scenario, the linker is invoked at boot-time `nowMs` (which is also the `started_at_ms`). The linker queries `EKEventStore.events(matching: predicateForEvents(withStart: nowMs - 15*60*1000, end: nowMs + 15*60*1000, calendars: nil))`. ±15 min window accommodates "meeting started a few minutes early/late vs calendar."

---

## 5. ZoomCalendarLinker — EventKit integration (moat)

### 5.1 Public protocol

```swift
// LeafCore/OS/ZoomCalendarLinker.swift
public protocol ZoomCalendarLinker: Sendable {
    /// Returns SHA256(EKEvent.eventIdentifier)[:16] hex string if an active EKEvent
    /// within ±15min of `atMs` contains a Zoom URL in .location, .notes, or .url.
    /// Returns nil otherwise. Fail-closed semantics; no errors thrown.
    func match(atMs: Int64) -> String?
}

public struct NoOpZoomCalendarLinker: ZoomCalendarLinker {
    public init() {}
    public func match(atMs: Int64) -> String? { nil }
}
```

### 5.2 Production impl (moat)

```swift
// LeafCorePrivate/Prod/Collectors/Apple/ProdZoomCalendarLinker.swift
public struct ProdZoomCalendarLinker: ZoomCalendarLinker {
    private let store: EKEventStore
    public init(store: EKEventStore) { self.store = store }

    public func match(atMs: Int64) -> String? {
        // ±15 min window
        let startDate = Date(timeIntervalSince1970: Double(atMs - 15*60*1000) / 1000.0)
        let endDate = Date(timeIntervalSince1970: Double(atMs + 15*60*1000) / 1000.0)
        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let events = store.events(matching: predicate)

        for event in events {
            let searchText = [event.location ?? "", event.notes ?? "", event.url?.absoluteString ?? ""]
                .joined(separator: " ")
            if Self.zoomURLRegex.firstMatch(in: searchText, range: NSRange(location: 0, length: searchText.utf16.count)) != nil {
                let identifier = event.eventIdentifier ?? ""
                guard !identifier.isEmpty else { continue }
                let hash = SHA256.hash(data: Data(identifier.utf8))
                let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
                return String(hex.prefix(16))
            }
        }
        return nil
    }

    // Subdomain-optional. Matches:
    //   us02web.zoom.us/j/12345678901
    //   zoom.us/j/12345678901            (bare domain)
    //   <company>.zoom.us/j/12345678901  (branded)
    //   zoom.us/my/jane.doe              (vanity PMI URL)
    //   zoom.us/wc/12345678901           (web client)
    //   zoom.us/s/12345678901            (schedule)
    private static let zoomURLRegex: NSRegularExpression = {
        let pattern = #"(?:[a-z0-9-]+\.)?zoom\.us/(j|wc|s|my)/[a-zA-Z0-9._-]+"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()
}
```

**ADR-010 guarantees:**

- Raw URL never returned, only the SHA256 hash of EKEvent's opaque identifier.
- EKEvent title, location, notes, URL never logged or written to any payload by this linker.
- EKEvent participants, organizer never read.
- Failure modes (empty events, nil identifiers, regex non-matches) all return nil — no exception leaks event data.

### 5.3 Failure behavior

If EventKit returns no permission / throws / returns empty: `match` returns nil. `_calendar_linked` not emitted. `_started` still emits with `linked_calendar_event_id: null`. Meeting tracking continues fully. **EventKit availability is a soft dependency.**

---

## 6. ZoomMeetingTopicRedactor — PMI regex (moat)

### 6.1 Public protocol

```swift
// LeafCore/OS/ZoomMeetingTopicRedactor.swift
public protocol ZoomMeetingTopicRedactor: Sendable {
    /// Redacts owner-PII patterns from a raw meeting topic.
    /// PMI format `<First> <Last>'s Personal Meeting Room` → "<pmi_meeting>".
    /// Otherwise pass-through.
    func redact(_ raw: String) -> String
}

public struct IdentityZoomMeetingTopicRedactor: ZoomMeetingTopicRedactor {
    public init() {}
    public func redact(_ raw: String) -> String { raw }
}
```

### 6.2 Production impl (moat)

```swift
// LeafCorePrivate/Prod/Collectors/Apple/ProdZoomMeetingTopicRedactor.swift
public struct ProdZoomMeetingTopicRedactor: ZoomMeetingTopicRedactor {
    public init() {}

    public func redact(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.pmiRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) != nil {
            return "<pmi_meeting>"
        }
        return trimmed
    }

    // EN-locale PMI format. Non-EN Zoom accounts may localize — best-effort.
    // Examples matched:
    //   "Alex Rivera's Personal Meeting Room"
    //   "John Smith's Personal Meeting Room"
    //   "Anne-Marie O'Connor's Personal Meeting Room"
    // Not matched (passes through):
    //   "Q1 Planning"
    //   "Personal Meeting Room"  (no apostrophe prefix)
    private static let pmiRegex: NSRegularExpression = {
        let pattern = #"^.+'s Personal Meeting Room$"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()
}
```

### 6.3 Where it's applied

In `ProdZoomAdapter.parse(descriptorData:for:)` — after extracting raw `topic` string from descriptor, BEFORE constructing `ZoomObservation`. So `ownMeetingTopic` already carries the bucket placeholder when it reaches either `ZoomStateMachine` (existing) or `ZoomMeetingDurationTracker` (new).

```swift
public func parse(_ descriptorData: Data, for bundleID: String) -> (any AdapterObservation)? {
    guard let descriptor = try? NSKeyedUnarchiver.unarchivedObject(...) else { return nil }
    guard descriptor.numberOfItems == 2 else { return nil }
    let stateRaw = descriptor.atIndex(1)?.stringValue ?? "not_in_meeting"
    let rawTopic = descriptor.atIndex(2)?.stringValue ?? ""
    let redactedTopic = redactor.redact(rawTopic)        // ← P5 addition
    let state = ZoomMeetingState(rawValue: stateRaw) ?? .notInMeeting
    return ZoomObservation(
        meetingState: state,
        ownMeetingTopic: redactedTopic.isEmpty ? nil : redactedTopic
    )
}
```

`redactor` is injected via `init(redactor: ZoomMeetingTopicRedactor = IdentityZoomMeetingTopicRedactor())` default; ProdZoomAdapter passes `ProdZoomMeetingTopicRedactor()` in its constructor.

---

## 7. EventLinksStore extension

### 7.1 New Schema enum members

```swift
// LeafCore/DB/Schema.swift
extension Schema.LinkKinds {
    public static let zoomToCalendarMeeting = "zoom_to_calendar_meeting"
}

extension Schema.TargetKinds {
    public static let calendarEvent = "calendar_event"
}

extension Schema.EventPayloadKeys {
    public static let linkedCalendarEventID = "linked_calendar_event_id"
}
```

### 7.2 LinkConfidenceValues new field

```swift
// LeafCore/DB/LinkDerivers.swift
public struct LinkConfidenceValues: Sendable {
    public let linearIDInText: Double
    public let branchNameLinearRef: Double
    public let prURLInSlack: Double
    public let prNumberHashRef: Double
    public let reviewerAssigned: Double
    public let zoomToCalendarMeeting: Double         // ← P5 addition

    public static let defaultPublic: Self = .init(
        linearIDInText: 0.5,
        branchNameLinearRef: 0.5,
        prURLInSlack: 0.5,
        prNumberHashRef: 0.5,
        reviewerAssigned: 1.0,
        zoomToCalendarMeeting: 0.95                  // ← URL regex is high-confidence
    )
}
```

Moat `prodLinkDerivers()` tuned-value, if any, lives in `LeafCorePrivate`. Public default 0.95 is fine for MVP.

### 7.3 deriveLinks new branch

```swift
// In EventLinksStore.deriveLinks, after the reviewer-fan-out branch (#4):

// 5) Zoom → Calendar link (zoom_meeting_started). Structured payload-field
// path — collector pre-computes hash via ZoomCalendarLinker.
if eventKind == "zoom_meeting_started",
   let linkedID = payload[Schema.EventPayloadKeys.linkedCalendarEventID],
   !linkedID.isEmpty {
    try insert(eventID: eventID,
               linkKind: Schema.LinkKinds.zoomToCalendarMeeting,
               targetKind: Schema.TargetKinds.calendarEvent,
               targetRef: linkedID,
               confidence: derivers.confidence.zoomToCalendarMeeting,
               createdAtMs: ts, in: db)
}
```

`payload[Schema.EventPayloadKeys.linkedCalendarEventID]` is the same SHA256 hash carried in the `_started` event payload. Idempotency: composite PK `(from_event_id, link_kind, target_ref)` ensures re-runs don't double-insert.

### 7.4 Reverse-lookup unchanged

`EventLinksStore.eventsLinkingTo(targetKind: "calendar_event", targetRef: <hash>)` automatically works once the new link_kind starts writing rows. No reader changes.

---

## 8. PresenceStateWriter integration

### 8.1 New Provider case

```swift
// LeafCore/Presence/PresenceStateWriter.swift
public enum Provider: String, Sendable, CaseIterable, Hashable {
    case github = "github"
    case linear = "linear"
    case slack = "slack"
    case googleCalendar = "google_calendar"
    case zoom = "zoom"                              // ← P5 addition
}
```

### 8.2 state_json shape

```json
{
  "meeting_active": true,
  "meeting_started_at_ms": 1715882400000,
  "cold_start": false,
  "linked_calendar_event_id": "a3f7b2c1d4e5f6a7",
  "last_observed_at_ms": 1715882430000
}
```

Fields:

| Field | Type | When written |
|---|---|---|
| `meeting_active` | bool | Always present. True when tracker state ∈ {`active`, `pendingEnd`}. False otherwise. |
| `meeting_started_at_ms` | int64? | Present only when `meeting_active=true`. Mirrors the active session's `started_at_ms`. |
| `cold_start` | bool? | Present only when `meeting_active=true`. Mirrors cold-start flag of current session. |
| `linked_calendar_event_id` | string? | Present only when `meeting_active=true` AND linker matched. SHA256[:16] hex. |
| `last_observed_at_ms` | int64 | Always present. Tick timestamp. |

### 8.3 Write cadence

Tracker `observe(_:nowMs:)` returns the new state; `ProdZoomAdapter.observe(...)` is wrapped by a per-tick adapter that calls `PresenceStateWriter.upsert(provider: .zoom, ...)` after each tick. Single composite write per tick.

### 8.4 ADR-010 walkback

No raw EKEvent data lands in `state_json`. Only the same SHA256 hash that the event payload carries. Walkback test asserts sentinels don't appear in `presence_state.zoom.state_json`.

---

## 9. ShareEventTypeKey registry

### 9.1 New cases

```swift
// LeafCore/Share/ShareEventTypeRegistry.swift
case zoomMeetingStarted = "zoom_meeting_started"
case zoomMeetingEnded = "zoom_meeting_ended"
case zoomMeetingCalendarLinked = "zoom_meeting_calendar_linked"
```

All three default OFF per ADR-020:

```swift
static let defaultEnabled: [ShareEventTypeKey: Bool] = [
    // ... existing entries
    .zoomMeetingStarted: false,
    .zoomMeetingEnded: false,
    .zoomMeetingCalendarLinked: false,
]
```

### 9.2 Category + description (Settings UI metadata)

```swift
case .zoomMeetingStarted:
    return ShareEventTypeMeta(
        label: "Zoom meeting started",
        description: "Records start timestamp and cold-start flag when a Zoom meeting is detected. No participants, titles, or URLs leave your device.",
        category: .meetings
    )
case .zoomMeetingEnded:
    return ShareEventTypeMeta(
        label: "Zoom meeting ended",
        description: "Records end timestamp and duration. No participants, titles, or URLs leave your device.",
        category: .meetings
    )
case .zoomMeetingCalendarLinked:
    return ShareEventTypeMeta(
        label: "Zoom meeting linked to calendar",
        description: "Records that this Zoom meeting matched a calendar event. Only an anonymized hash of the calendar event ID is recorded — no titles, attendees, or URLs.",
        category: .meetings
    )
```

### 9.3 Total registry count

152 baseline (Track-4 S4) → **155** post-P5. Within contract §6.2 estimate of ~3 entries.

---

## 10. UI surface — Settings → Local Apps → Zoom

### 10.1 Existing baseline

```
[v] Zoom                                      ▼ expanded
    [v] Meeting state changes (existing S2)
    [v] Meeting topic (existing S2 sub-field)
```

### 10.2 Post-P5 layout

```
[v] Zoom                                      ▼ expanded
    [v] Meeting state changes (existing S2)
    [v] Meeting topic (existing S2 sub-field)
    [v] Meeting started events ← new
    [v] Meeting ended events ← new
    [v] Link Zoom to your calendar events ← new (depends on "Meeting started")
```

Toggle copy per §9.2. Calendar-linked sub-toggle is **disabled in the UI when "Meeting started events" is off** — there's no `_started` event to attach a link to. UI grays out + tooltip "Requires 'Meeting started events' enabled."

### 10.3 Privacy walkback dashboard

Existing Track-2 D4 surface auto-renders new event_kinds via `ShareEventTypeRegistry`. No new UI code needed.

---

## 11. ActivityFeedMapper + EventKindIcon

### 11.1 ActivityFeedMapper.mapLocalOS additions

```swift
case "zoom_meeting_started":
    let coldStart = payload["cold_start"] == "true"
    primary = coldStart ? "Zoom meeting (already in progress)" : "Zoom meeting started"
    secondary = nil  // no topic re-emit; user can rely on _name_observed

case "zoom_meeting_ended":
    let duration = Int(payload["duration_seconds"] ?? "0") ?? 0
    let formatted = formatDurationCompact(duration)  // helper: "1h 23m" / "45m" / "8s"
    primary = "Zoom meeting ended"
    secondary = "Duration: \(formatted)"

case "zoom_meeting_calendar_linked":
    primary = "Zoom meeting linked to calendar"
    secondary = nil
```

`formatDurationCompact` — pure helper, unit-tested separately.

### 11.2 EventKindIcon additions

```swift
case "zoom_meeting_started": return "video.fill"
case "zoom_meeting_ended": return "video.slash"
case "zoom_meeting_calendar_linked": return "link.circle"
```

(Different SF Symbols than existing `video.circle` for baseline kinds — visual distinction between transition events and aggregated session events.)

### 11.3 trackFourLocalOSKinds whitelist append

Append all 3 new kinds. **DispatchCoverageTests #16** asserts the new kinds are present in both the whitelist + mapper switch.

---

## 12. RelayBodyLeakageTests — walkback expansion

### 12.1 Sentinel families per event_kind

Per event_kind, inject sentinels at forbidden paths and assert they don't appear in:
- `payload_json` of the emitted RawEvent
- `state_json` of `presence_state.zoom` row
- `events_fts_meta` body column (for kinds that route to FTS — none of P5's 3 new kinds do, but assertion held for defense)

8 sentinel families × 3 new event_kinds = **24 net new walkback assertions**.

### 12.2 Sentinel definitions

| Family | Sentinel value | Forbidden positions |
|---|---|---|
| `attendees` | `SECRET-ZOOM-ATTENDEES-P5` | Any payload key matching `attendees`, `participants`, `participant_names`. |
| `password` | `SECRET-ZOOM-PASSWORD-P5` | Any payload key matching `password`, `passcode`, `meeting_password`. |
| `chat_history` | `SECRET-ZOOM-CHAT-P5` | Any payload key matching `chat`, `chat_history`, `chat_messages`. |
| `recording_state` | `SECRET-ZOOM-RECORDING-P5` | Any payload key matching `recording`, `is_recording`, `recording_state`. |
| `participant_names` | `SECRET-ZOOM-PARTICIPANTS-P5` | (Defense-in-depth alias of attendees.) |
| `screen_share_content` | `SECRET-ZOOM-SHARE-CONTENT-P5` | Any payload key matching `screen_share_content`, `shared_screen_app`, `shared_screen_window`. |
| `meeting_join_url` | `SECRET-ZOOM-JOIN-URL-P5` | Any payload key matching `meeting_join_url`, `zoom_url`, `conference_uri`. |
| `pmi_name` | `Alex Rivera's Personal Meeting Room` (sentinel raw PMI string) | Asserted that bucketed `<pmi_meeting>` appears in event payload instead, raw never appears. |

### 12.3 Test method skeleton

```swift
func testRelayDoesNotLeakZoomAttendees_P5_Started() {
    let payload: [String: String] = [
        "event_kind": "zoom_meeting_started",
        "started_at_ms": "1715882400000",
        "cold_start": "false",
        "linked_calendar_event_id": "",
        "attendees": "SECRET-ZOOM-ATTENDEES-P5"      // inject
    ]
    let rawEvent = RawEvent(timestamp: Date(), signalType: .context, bundleID: "us.zoom.xos", payload: payload)
    let envelope = relayBuilder.build(rawEvent)
    XCTAssertFalse(envelope.contains("SECRET-ZOOM-ATTENDEES-P5"))
}
```

Iterate per (family × event_kind) combination. 24 functions total. Naming: `testRelayDoesNotLeakZoom<Family>_P5_<Kind>`.

### 12.4 PMI-specific test

```swift
func testProdZoomMeetingTopicRedactorStripsPMIName_P5() {
    let r = ProdZoomMeetingTopicRedactor()
    XCTAssertEqual(r.redact("Alex Rivera's Personal Meeting Room"), "<pmi_meeting>")
    XCTAssertEqual(r.redact("Anne-Marie O'Connor's Personal Meeting Room"), "<pmi_meeting>")
    XCTAssertEqual(r.redact("Q1 Planning"), "Q1 Planning")
    XCTAssertEqual(r.redact(""), "")
}

func testProdZoomAdapterParseRedactsPMIBeforeObservation_P5() {
    // Inject NSAppleEventDescriptor list ["in_meeting", "Alex's Personal Meeting Room"]
    // Assert resulting ZoomObservation.ownMeetingTopic == "<pmi_meeting>"
}
```

Both assertions critical — first checks redactor logic; second checks wiring.

---

## 13. DispatchCoverageTests parity fence #16

```swift
func testDispatchCoverageTrack6P5LocalOSKindsCovered() {
    let p5Kinds = [
        "zoom_meeting_started",
        "zoom_meeting_ended",
        "zoom_meeting_calendar_linked"
    ]
    for kind in p5Kinds {
        XCTAssertTrue(ActivityFeedMapper.trackFourLocalOSKinds.contains(kind))
        // also assert each kind has an EventKindIcon mapping
        XCTAssertNotEqual(EventKindIcon.symbol(forEventKind: kind), "questionmark.circle")
    }
}

func testEventLinksStoreHandlesZoomCalendarLinkKind_P5() {
    // Insert a synthetic zoom_meeting_started event with linked_calendar_event_id payload field.
    // Run deriveLinks. Assert event_links table row exists with link_kind=zoom_to_calendar_meeting.
}
```

---

## 14. Test plan

### 14.1 Unit tests (public)

| Test class | Coverage |
|---|---|
| `ZoomMeetingDurationTrackerTests` | All transitions in §4.3 transition table (cold-start, warm-start GRACE_START, false-alarm pendingStart→idle, active→pendingEnd GRACE_END, pendingEnd→active revert with dropped counter, multiple-session sequence). ~25 cases. |
| `ZoomCalendarLinkerProtocolTests` | NoOpZoomCalendarLinker returns nil always. Behavioral contract test. ~3 cases. |
| `ZoomMeetingTopicRedactorProtocolTests` | IdentityZoomMeetingTopicRedactor pass-through. ~3 cases. |

### 14.2 Unit tests (moat — LeafCorePrivateTests)

| Test class | Coverage |
|---|---|
| `ProdZoomCalendarLinkerTests` | URL regex match cases: standard `zoom.us/j/<id>`, custom subdomain `<company>.zoom.us/j/<id>`, `zoom.us/wc/<id>` (web client), `zoom.us/my/<vanity>` (personal). Non-match: `meet.google.com`, plain text. EKEvent stub fan-out: 0 events, 1 match, multiple events first-match wins, identifier nil → skip. SHA256 stability across runs. ~12 cases. |
| `ProdZoomMeetingTopicRedactorTests` | PMI EN format match cases (1-word, 2-word, hyphenated, apostrophe in name like "O'Connor", trailing whitespace). Non-match: "Q1 Planning", "Personal Meeting Room" (no apostrophe prefix), empty string. ~10 cases. |
| `ProdZoomAdapterParserTests` | Parser applies redactor: inject raw PMI string in NSAppleEventDescriptor, parse, assert `ownMeetingTopic == "<pmi_meeting>"`. Non-PMI string passes through. Empty topic → nil. 2-element descriptor invariant. ~6 cases. |

### 14.3 Integration tests

| Test class | Coverage |
|---|---|
| `RelayBodyLeakageTests` (extended) | 24 new walkback assertions (§12.2 table × 3 new event_kinds). All sentinels asserted absent from payload + presence_state. |
| `DispatchCoverageTests` #16 | §13 parity fence. |
| `PresenceStateWriterZoomTests` | New `.zoom` Provider case writes correct JSON shape. meeting_active=false omits transient fields. meeting_active=true includes all. ADR-010 walkback. ~5 cases. |
| `EventLinksStoreZoomTests` | deriveLinks branch for `zoom_meeting_started` with `linked_calendar_event_id` field writes correct row. Empty/null payload field → no row. Idempotency on re-run. ~4 cases. |

### 14.4 End-to-end (existing collector tick)

`ZoomCollectorEndToEndTests` (new): synthetic AppleScript descriptor → ProdZoomAdapter parse + observe → assert both baseline events AND new tracker events emitted. PMI redaction applied. Calendar linker stub returns hash → assert `_calendar_linked` emitted with correct payload. ~6 scenarios.

### 14.5 Net test count

Approximately **80–100 new test cases**, baseline 2012 → ~2092–2112. Final count locked at Stage 7 verification.

---

## 15. Migration / schema

**No migrations.** P5 uses:

- Existing `events` table for the 3 new event_kinds.
- Existing `event_links` table (M013) with a new `link_kind` constant.
- Existing `presence_state` table (M005) with a new `provider` value.

**M025 stays reserved for P2 Xcode** per contract §6.1. P5 takes no migration slot.

---

## 16. Future work (P5.1+)

| Item | Rationale | Estimate |
|---|---|---|
| Screen-share started/ended event_kinds via AS menu-item-existence | Marginal value; AS extension straightforward but bumps Local Apps + walkback surface. | Phase 4.9 or P5.1. |
| Video state changed | "Camera-on" derived insight. | P5.1. |
| CoreAudio `kAudioProcessPropertyPID` evidence triangulation | Improves "Zoom is audio-only meeting" detection where Zoom AS `is meeting` lags. | P5.1 if false-negative rate problematic. |
| AXObserver `kAXTitleChangedNotification` for sub-second start detection | Live-presence UX. 30s poll is acceptable for duration tracking but not for "in real-time, show me my teammate just joined a meeting." | Track-5 / Phase 5.4 alignment. |
| Zoom REST API (OAuth + post-hoc duration accuracy) | Past-meeting reconciliation for when Leaf wasn't running. Webhook live path remains infeasible. | Phase 4.9 if Derived Insights requires it. |
| EventKit reconciliation with P4 Google Calendar | Cross-source dedupe for the same logical event (Google Calendar API + EventKit-via-macOS-Calendar both see it). | Phase 4.9. |
| `<pmi:self>` bucket vs `<pmi:other>` differentiation | Compare EKEvent.organizer.email with user's email. Requires P4 workspace_id derivation precedent. | Phase 4.9. |
| Non-EN PMI regex localization | Best-effort coverage of localized Zoom defaults. | P5.1 if user reports surface. |
| `meeting_kind: "webinar"` discrimination | "Zoom Webinar" window title → separate field. | P5.1. |

---

## 17. Acceptance criteria

P5 ships when **all** apply:

1. **Build green** on all 5 xcodebuild schemes (Leaf / LeafAgent / LeafMCP / LeafCore SPM / LeafCorePrivate SPM).
2. **All SPM tests pass.** Baseline 2012 + ~80–100 new = ~2092–2112. Final count documented in current-state.md ship line.
3. **3 new event_kinds wired end-to-end:** `zoom_meeting_started`, `zoom_meeting_ended`, `zoom_meeting_calendar_linked`. Visible in Activity Feed (mapper + icon). Sub-toggles visible in Settings → Local Apps → Zoom.
4. **Existing S2 event_kinds keep firing.** `zoom_meeting_state_changed` and `zoom_meeting_name_observed` unchanged in behavior (regression test: existing ZoomStateMachineTests pass without modification).
5. **PMI redaction asserted at parser boundary.** Sentinel test passes.
6. **24 new RelayBodyLeakageTests walkbacks** added; all pass.
7. **DispatchCoverageTests #16** new parity fence passes.
8. **0 new TCC prompts.** Manual smoke confirms no new dialog appears when starting Agent.
9. **EventLinksStore row written** when synthetic `zoom_meeting_started` with `linked_calendar_event_id` emitted. Reverse-lookup `eventsLinkingTo(targetKind: "calendar_event", targetRef: <hash>)` returns the event ID.
10. **`presence_state.zoom` row updated** every tick. `meeting_active=true` mid-meeting, `false` after GRACE_END.
11. **Manual smoke on author's Mac** (substrate-only — no internet dep): Open Zoom → start meeting → Leaf Agent emits `zoom_meeting_started` within ~60s (worst case 2 ticks @ 30s + GRACE_START). End meeting → `zoom_meeting_ended` emitted within ~60s of leave. Duration_seconds matches wall-clock ±60s. Repeat with a scheduled EKEvent containing `zoom.us/j/<id>` URL → `_calendar_linked` event emitted with hash; reverse-lookup confirms.
12. **Independent code review** verdict APPROVE or APPROVE-WITH-NITS. Every comment addressed.
13. **Final commit on `feature/track-6-P5-zoom-deep` + push.** **NOT merged** — collective merge in track-6-integration is a separate session.

---

## 18. Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Coalescer GRACE_END=30s too aggressive — user briefly switches networks, Leaf records 2 separate sessions instead of 1 | MED | Tune via moat constants if production smoke flags. `dropped_transitions_count` field on `_ended` lets Derived Insights detect chronic flakiness. |
| EventKit predicate slow when user has 1000+ calendars / events | LOW | EventKit predicate is local-DB. ±15min window narrows to <100 events typical. Async-context-free is fine for collector tick path. If issue surfaces — wrap in DispatchQueue.global tick. |
| AS `tell application "zoom.us"` blocks longer than 3.0s under load | LOW | Existing override `timeoutSec=3.0` stays. Failure mode: parse returns nil, observation skipped. Tracker re-affirms previous state next tick. |
| Zoom AS dictionary changes in future release (e.g. `is meeting` removed) | LOW | Existing S2 covers same surface; failure cascades to both. Watch for breakage; P5.1 fallback to AX UI-scripting. |
| PMI regex misses localized non-EN format | LOW | Document as best-effort. Sentinel test only covers EN. P5.1 expand. |
| EventKit permission revoked mid-session | LOW | Linker fail-closed (returns nil). Meeting tracking continues. |
| Cold-start emits inaccurate started_at_ms (= boot time, not real meeting start) | MED | `cold_start: true` flag explicit. `cold_start_origin: true` on `_ended`. Derived Insights can filter. |
| Calendar linker matches wrong EKEvent (multiple Zoom URLs in ±15min) | LOW | First-match wins (chronologically first). Acceptable for MVP — meeting overlap is rare. P5.1 refine if needed. |

---

## 19. Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-05-16 | **Cross-link via EventKit inline (Path A) instead of P4-deferred-detector (Path B).** | Contract hinted Path B with `link_kind=zoom_to_gcal_meeting`. Stage 0 research revealed P4 forbids `conference_uri` in payload (42 walkbacks confirm) — Path B caps at confidence ~0.7 with no Zoom-vs-Webex/Jitsi discrimination. Path A reaches 0.95 via raw URL regex (URL never persisted, only SHA256 hash). Path A also is independent of P4 acceptance gate (blocked on GCP verification 2-6 wk). Decision deviates from contract literal name `zoom_to_gcal_meeting` → `zoom_to_calendar_meeting` (calendar-source agnostic, supports iCloud/Outlook/CalDAV/Google-via-Calendar.app via single EventKit predicate). |
| 2026-05-16 | **Defer Zoom REST API to P5.1.** | Webhook live-state path infeasible for individual-dev customers (account-scoped, documented flaky). Post-hoc reconciliation value insufficient for MVP. Adds OAuth surface + 7+ walkbacks per response. Defer until Derived Insights surfaces accuracy requirement. |
| 2026-05-16 | **PMI regex L4 redaction in parser, not state machine.** | Parser is single ingress point — redaction at parser benefits both existing `_name_observed` AND new `_started/_ended` carrying topic. Defense-in-depth. Test: sentinel walkback at parser level. |
| 2026-05-16 | **Drop screen-share event_kinds from P5 MVP (defer to P5.1).** | Marginal per research §6. AS extension adds System Events surface complexity. Focus MVP on Critical signals (duration + calendar link). |
| 2026-05-16 | **Defer evidence triangulation (CoreAudio PID + NSWorkspace + AX listener) to P5.1.** | Existing AS-reported `is meeting` boolean from Zoom is already high-confidence. Triangulation only helps exotic "Zoom recording but `is meeting`==false" edge case. Saves implementation surface + new Apple API dependency. |
| 2026-05-16 | **Keep 30s polling (no AXObserver).** | Worst-case 60s detection delay (2 ticks @ 30s + GRACE_START) acceptable for duration-tracking use case. AXObserver adds C-pointer cleanup surface. Defer to P5.1 if live-presence UX requirement emerges. |
| 2026-05-16 | **Keep both existing S2 event_kinds.** | Zero regression risk. Floor signals continue. New tracker layers on top. Track-3 D3 precedent. |
| 2026-05-16 | **GRACE_START=5s, GRACE_END=30s (moat constants).** | With 30s polling, both values map to "wait at least one more tick to confirm." 30s GRACE_END matches Track-4 S3 intensity coalescer precedent. Tunable via moat without breaking public protocol. |

---

**End spec. Stage 4 plan next.**
