# Track-6 P4 — Google Calendar Deep · Spec

**Phase:** Track-6 P4 (Google Calendar Deep) — Leaf's first Layer B Google API provider
**Stage:** 3 — Spec (this doc); written after Stage 0 Research + Stage 2 Brainstorm
**Date:** 2026-05-16
**Author:** Alex + Claude
**Contract:** [`2026-05-15-track-6-existing-surface-depth-contract.md`](2026-05-15-track-6-existing-surface-depth-contract.md)
**Research companion:** [`2026-05-16-track-6-P4-google-calendar-research.md`](2026-05-16-track-6-P4-google-calendar-research.md) — Stage 0 substrate + vendor API ceiling + EventKit + OSS recon + ceiling-vs-effort table

This is the implementation contract. The research doc is the why; this doc is the what.

---

## 1. Goals

1. Ship a Layer B Google Calendar API collector that captures **richer signals than EventKit can provide on macOS** — specifically `eventType` discriminator (focusTime / outOfOffice / workingLocation), reliable `responseStatus`, structured `conferenceData`, and authoritative server `updated` timestamps.
2. Emit **6 new `event_kind` discriminators** (1 omnibus + 5 transition-bearing) with privacy-clean payloads per ADR-010.
3. Time-cross transitions (focus block / OOO / working location starts and ends) emitted from collector tick — no separate detector module.
4. Multi-calendar fan-out — all calendars where `accessRole ∈ {owner, writer, reader}`, with per-calendar 410-Gone isolation.
5. Reuse existing OAuth substrate (PKCE + LoopbackCallbackListener from Linear's namespace) — no refactor.
6. Augment `presence_state` with a new `googleCalendar` provider row.
7. Pass full smoke (Section 10) on author's Mac with real Google account.

---

## 2. Locked decisions (from Stage 0 user gate)

| ID | Decision | Recorded in research |
|---|---|---|
| OQ-1 | OAuth scope: `https://www.googleapis.com/auth/calendar.readonly` (single broad scope). | §2.1 |
| OQ-2 | Calendars in scope at runtime: ALL subscribed (filter `accessRole IN (owner, writer, reader)`, skip `freeBusyReader`). | §1.5, §8 |
| OQ-3 | EventKit reconciliation: γ Hybrid — independent collectors; dedupe deferred to Phase 4.9 via `(iCalUID, start_ms)` join. | §8 |
| OQ-A | M027 cursor storage: reuse `provider_snapshots` (M015) for syncTokens; one new tracking table for time-crossings. | §0.5, §8 |
| OQ-4 | `events.watch` push notifications: defer to v1.1 (5-min poll covers MVP). | §1.3, §8 |
| OAuth client | Create new Google Cloud project `leaf-prod`; submit brand verification (2-3 days) + sensitive scope verification (2-6 weeks); 100-test-user cap acceptable for alpha. | §2.5 |
| BR-1 | Event_kind taxonomy: Hybrid (omnibus + transition pairs) — 6 new kinds. | Brainstorm |
| BR-2 | Time-crossing detection: collector-internal tick scan + M027 tracking table. | Brainstorm |

---

## 3. Out of scope (this phase)

- `events.watch` push notifications (relay extension + Search Console domain verification + channel renewal) — v1.1.
- Cross-source dedupe between EventKit `meeting_state_*` and `google_calendar_*` — Phase 4.9 Derived Insights via `(iCalUID, start_ms)` join.
- Modification of Track-4 S1 EventKit Calendar collector (`LeafAgent/Collectors/CalendarCollector.swift`, `LeafCore/OS/MeetingObservation.swift`) — P4 is purely additive.
- OAuth incremental authorization (adding scopes later) — v1.1.
- Multi-account-per-user (multiple Google accounts on one Leaf install) — v1.1 (M005 composite-PK lift).
- Calendar.app capture extensions (Track-4 S2 covers AppleScript view-state already).
- New MCP tools — P4 adds zero MCP tools per Track-6 contract §4.
- Building/floor/desk IDs from `workingLocationProperties.officeLocation` — privacy-conservative skip MVP (research doc §1.4 Section "wokingLocationProperties.officeLocation.*" — debatable, deferred).

---

## 4. Architecture

### 4.1 File layout

```
Leaf/Integrations/GoogleCalendar/                          ← NEW directory, mirrors Leaf/Integrations/{Linear,Slack}/
  GoogleCalendarOAuthService.swift                         — PKCE+loopback orchestration, ConnectionState machine
  GoogleCalendarOAuthClient.swift                          — POST /token, refresh, error decode
  (NO own PKCE.swift — reuses Leaf/Integrations/Linear/PKCE.swift like Slack does)
  (NO own LoopbackCallbackListener.swift — reuses Linear's like Slack does)

Packages/LeafCore/Sources/LeafCore/Integrations/GoogleCalendar/
  GoogleCalendarOAuthEndpoints.swift                       — auth/token URLs + scope strings + client_id read from Info.plist
  GoogleCalendarTokenRefresher.swift                       — proactive + reactive refresh, mirrors SlackTokenRefresher
  GoogleCalendarAPIClient.swift                            — public protocol (sync events.list / calendarList.list / userinfo)
  GoogleCalendarSyncTokenStore.swift                       — provider_snapshots wrapper (per-calendar token, calendarList token, known_calendars snapshot)
  GoogleCalendarTrackerStore.swift                         — M027 typed-event tracker UPSERT + scan + cleanup
  GoogleCalendarEventKinds.swift                           — enum of 6 kinds (mirrors ClaudeCodeEventKinds.swift)
  GoogleCalendarEventMapper.swift                          — Event JSON → RawEvent emit (privacy filter HERE)
  GoogleCalendarAPI.swift                                  — request/response Codable shapes

Packages/LeafCore/Sources/LeafCorePrivate/Prod/Integrations/GoogleCalendar/
  ProdGoogleCalendarAPIClient.swift                        — concrete URLSession impl (moat: retry + backoff + headers)

Packages/LeafCore/Sources/LeafCore/Collectors/
  GoogleCalendarCollector.swift                            — single 5min tick loop

Packages/LeafCore/Sources/LeafCore/DB/Migrations/
  M027_GoogleCalendarTracker.swift                         — single new table per Section 5
```

### 4.2 Substrate changes (small, isolated)

| Change | Site | Type |
|---|---|---|
| `PresenceStateWriter.Provider` enum gains case `googleCalendar = "google_calendar"`. | `LeafCore/DB/PresenceStateWriter.swift` | Append-only enum extension. Step 0 of plan: grep exhaustive switches on this enum and add new case or default branch in every consumer. |
| `IntegrationProvider` enum gains `.googleCalendar` if not present. | `LeafCore/DB/IntegrationRecord.swift` (or wherever defined) | Append-only enum extension; same consumer-grep discipline. |
| `Schema.EventPayloadKeys` may need new constants for new payload fields. | `LeafCore/DB/Schema.swift` | Append-only constants. |
| `ShareEventTypeKey` gains 6 cases (Section 6). | `LeafCore/Share/ShareEventTypeRegistry.swift` | Append-only; default OFF per ADR-020. |
| `ActivityFeedMapper.mapIntegration` gains `case "google_calendar"` branch + `mapGoogleCalendar(...)` function. | `LeafCore/Insights/ActivityFeedMapper.swift` | Append-only; covered by DispatchCoverageTests #15. |
| `EventKindIcon.symbol(for:)` gains 4 new case-mappings. | `LeafCore/Insights/EventKindIcon.swift` | Append-only. |
| `CollectorID` enum gains `.googleCalendarPolling`. | `LeafCore/DB/CollectorOffsets.swift` (or wherever defined — used at e.g. `ClaudeCodeCollector.swift:219`, `GitHubWarmCollector.swift:191`, `SlackCollector.swift:179`) | Append-only. |

**No changes to:** EventKit/Calendar collector code (γ Hybrid); Track-1 detector pipeline; existing MCP tools; existing OAuth code for Linear/Slack/GitHub; existing relay code.

### 4.3 Code reuse from existing OAuth substrate

Reuse verbatim, no refactor (verified — Slack already reuses these from Linear's namespace):
- `Leaf/Integrations/Linear/PKCE.swift` — `PKCE.makeChallenge()` returns `(verifier, challenge, state)` triple.
- `Leaf/Integrations/Linear/LoopbackCallbackListener.swift` — NWListener wrapper; takes a port parameter. P4 uses `port=0` (kernel-assigned ephemeral); Linear/Slack use fixed ports for historical reasons.

---

## 5. Schema — M027 migration

### 5.1 New table

```sql
-- M027_GoogleCalendarTracker.swift
-- Tracks Google Calendar typed events (focusTime / outOfOffice / workingLocation)
-- for collector-internal time-crossing transitions. Receives UPSERT per syncToken delta,
-- scanned each tick to emit _started / _ended / _changed event_kind rows.

CREATE TABLE google_calendar_typed_event_tracker (
    event_id              TEXT NOT NULL,         -- Google event.id (instance-level for recurring exceptions)
    calendar_id           TEXT NOT NULL,         -- so 410-on-calendar wipe scopes cleanly
    i_cal_uid             TEXT,                  -- for Phase 4.9 cross-source dedupe with EventKit
    event_type            TEXT NOT NULL,         -- 'focusTime' | 'outOfOffice' | 'workingLocation'
    start_ms              INTEGER NOT NULL,
    end_ms                INTEGER NOT NULL,
    started_emitted_at_ms INTEGER,               -- NULL = transition not yet fired
    ended_emitted_at_ms   INTEGER,               -- NULL = transition not yet fired; UNUSED for workingLocation (single-shot)
    upserted_at_ms        INTEGER NOT NULL,
    PRIMARY KEY (event_id)
);

CREATE INDEX idx_gcal_tracker_scan_started
  ON google_calendar_typed_event_tracker(start_ms)
  WHERE started_emitted_at_ms IS NULL;

CREATE INDEX idx_gcal_tracker_scan_ended
  ON google_calendar_typed_event_tracker(end_ms)
  WHERE started_emitted_at_ms IS NOT NULL AND ended_emitted_at_ms IS NULL;

CREATE INDEX idx_gcal_tracker_by_calendar
  ON google_calendar_typed_event_tracker(calendar_id);
```

### 5.2 `provider_snapshots` rows (M015, no schema change)

Three `snapshot_kind` values for `provider="google_calendar"`:

| `snapshot_kind` | `snapshot_json` shape | Purpose |
|---|---|---|
| `sync_token:events:<calendar_id>` | `{"token": "<opaque>", "last_full_sync_at_ms": <epoch_ms>, "bootstrap_in_progress": <bool>}` | One row per known calendar. `bootstrap_in_progress=true` while initial pagination walk is in flight; flips to false only after terminal page persisted. |
| `sync_token:calendar_list` | `{"token": "<opaque>", "last_full_sync_at_ms": <epoch_ms>}` | Single row for the `calendarList.list` cursor. |
| `known_calendars` | `[{"id": "...", "summary": "...", "summaryOverride": "...", "access_role": "owner\|writer\|reader", "primary": <bool>, "color_id": "...", "time_zone": "..."}, ...]` | Snapshot of all calendars we currently poll. Diffed each 1h calendarList tick. |

### 5.3 `integrations` table (M004, no schema change)

One row added on connect:
```
provider="google_calendar"
workspace_id=<primary calendar email, plaintext — see §7.3 rationale>
workspace_name=<display name from calendarList primary entry>
access_token=<from token exchange>
refresh_token=<from token exchange; required because access_type=offline+prompt=consent>
expires_at_ms=<connectedAt + expires_in × 1000>
scope="https://www.googleapis.com/auth/calendar.readonly"
connected_at_ms=<now>
updated_ms=<now>
```

---

## 6. Event_kind taxonomy

### 6.1 Enum

```swift
// LeafCore/Integrations/GoogleCalendar/GoogleCalendarEventKinds.swift

public enum GoogleCalendarEventKind: String, CaseIterable, Sendable {
    case eventObserved              = "google_calendar_event_observed"
    case focusBlockStarted          = "google_calendar_focus_block_started"
    case focusBlockEnded            = "google_calendar_focus_block_ended"
    case oooStarted                 = "google_calendar_ooo_started"
    case oooEnded                   = "google_calendar_ooo_ended"
    case workingLocationChanged     = "google_calendar_working_location_changed"
}
```

### 6.2 ShareEventTypeKey additions (registry, default OFF)

```swift
case googleCalendarEventObserved          = "google_calendar_event_observed"
case googleCalendarFocusBlockStarted      = "google_calendar_focus_block_started"
case googleCalendarFocusBlockEnded        = "google_calendar_focus_block_ended"
case googleCalendarOOOStarted             = "google_calendar_ooo_started"
case googleCalendarOOOEnded               = "google_calendar_ooo_ended"
case googleCalendarWorkingLocationChanged = "google_calendar_working_location_changed"
```

**Baseline 152 → target 158.** Within contract §6.2 ballpark.

### 6.3 Payload shapes (ADR-010-clean)

**`google_calendar_event_observed`** (omnibus, fires on every syncToken-delta event for `eventType IN {default, focusTime, outOfOffice, workingLocation}`):

```json
{
  "source": "google_calendar",
  "event_kind": "google_calendar_event_observed",
  "event_id": "<opaque>",
  "i_cal_uid": "<opaque>@google.com",
  "calendar_id": "<id or 'primary'>",
  "calendar_access_role": "owner|writer|reader",
  "status": "confirmed|tentative|cancelled",
  "summary": "<L4 title — gated by ShareEventTypeKey.googleCalendarEventObserved>",
  "event_type": "default|focusTime|outOfOffice|workingLocation|other",
  "start_ms": <epoch_ms>,
  "end_ms": <epoch_ms>,
  "is_all_day": <bool>,
  "timezone": "<IANA>",
  "transparency": "opaque|transparent",
  "visibility": "default|public|private|confidential",
  "attendees_count": <int>,
  "external_attendee_count": <int>,
  "self_response_status": "needsAction|accepted|declined|tentative|unknown",
  "self_is_organizer": <bool>,
  "self_is_creator": <bool>,
  "is_recurring_instance": <bool>,
  "recurrence_frequency_bucket": "one_off|daily|weekly|monthly|yearly|other",
  "conference_entry_point_type": "video|phone|sip|more|none",
  "conference_solution_type": "hangoutsMeet|addOn|other|none",
  "created_ms": <epoch_ms>,
  "updated_ms": <epoch_ms>
}
```

**`google_calendar_focus_block_started`** + `_ended` (transition delta, fires when tracker scan detects clock crossing):

`_started`:
```json
{
  "source": "google_calendar",
  "event_kind": "google_calendar_focus_block_started",
  "event_id": "<from tracker>",
  "i_cal_uid": "<opaque>",
  "calendar_id": "<id>",
  "start_ms": <epoch_ms>,
  "end_ms": <epoch_ms>,
  "auto_decline_mode": "declineNone|declineOnlyNewConflictingInvitations|declineAllConflictingInvitations",
  "chat_status": "available|doNotDisturb"
}
```

`_ended` (same shape, no `auto_decline_mode` / `chat_status` — operational fields meaningful only during active phase):
```json
{
  "source": "google_calendar",
  "event_kind": "google_calendar_focus_block_ended",
  "event_id": "<from tracker>",
  "i_cal_uid": "<opaque>",
  "calendar_id": "<id>",
  "start_ms": <epoch_ms>,
  "end_ms": <epoch_ms>
}
```

**`google_calendar_ooo_started`** + `_ended`:

```json
{
  "source": "google_calendar",
  "event_kind": "google_calendar_ooo_started",
  "event_id": "<from tracker>",
  "i_cal_uid": "<opaque>",
  "calendar_id": "<id>",
  "start_ms": <epoch_ms>,
  "end_ms": <epoch_ms>,
  "auto_decline_mode": "declineNone|declineOnlyNewConflictingInvitations|declineAllConflictingInvitations"
}
```
`_ended` same shape minus `auto_decline_mode`. **NO `decline_message`** — user-authored body, ADR-010 forbidden.

**`google_calendar_working_location_changed`** (single-shot, fires once at start_ms; no _ended pair):

```json
{
  "source": "google_calendar",
  "event_kind": "google_calendar_working_location_changed",
  "event_id": "<from tracker>",
  "calendar_id": "<id>",
  "start_ms": <epoch_ms>,
  "end_ms": <epoch_ms>,
  "working_location_type": "homeOffice|officeLocation|customLocation"
}
```
**NO `buildingId` / `floorId` / `deskId`** (workspace opaque IDs, conservative skip MVP). **NO `customLocation.label`** (user-authored). Next workingLocation change fires its own `_changed` event — implicit transitions chain.

### 6.4 Forbidden payload fields (ADR-010 walkback)

Every field listed below MUST be absent from every `google_calendar_*` payload AND from `presence_state.google_calendar.state_json`. Asserted by `RelayBodyLeakageTests` sentinel injection (7 sentinels × 6 kinds = 42 assertions).

| Field | Why forbidden |
|---|---|
| `description` (Event resource body) | User-authored body |
| `location` (free-text) | May contain addresses / room codes / PII |
| `attendees[].email` | PII |
| `attendees[].displayName` | PII |
| `attendees[].id` | Stable raw identifier |
| `attendees[].comment` | User-authored body |
| `creator.email` / `organizer.email` | PII (we keep `.self` bool only) |
| `creator.displayName` / `organizer.displayName` | PII |
| `htmlLink` | Reveals event existence to whoever sees DB; not needed for derived insights |
| `hangoutLink` / `conferenceData.entryPoints[].uri` | Meeting URLs leak meeting IDs and passwords |
| `conferenceData.entryPoints[].pin` / `.password` / `.accessCode` / `.passcode` / `.meetingCode` | Credentials |
| `conferenceData.conferenceId` | Joinable opaque identifier |
| `focusTimeProperties.declineMessage` / `outOfOfficeProperties.declineMessage` | User-authored body |
| `workingLocationProperties.officeLocation.buildingId` / `.floorId` / `.deskId` / `.label` | Workspace-specific opaque IDs (debatable; conservative skip) |
| `workingLocationProperties.customLocation.label` | User-authored free text |
| `extendedProperties.private` / `.shared` | App-defined; high-risk for accidental PII |
| `gadget` | Deprecated, body content |
| `source.url` / `source.title` | User-authored |
| `attachments[].fileId` / `.fileUrl` / `.title` | Drive identifiers + user-authored titles |
| `birthdayProperties.contact` | Contact PII reference |

### 6.5 Blocklist filters (collector-side, BEFORE emit)

Skip entirely (never emit `_event_observed` row):
- `eventType == "fromGmail"` — auto-extracted from Gmail body content.
- `eventType == "birthday"` — contains contact PII via birthdayProperties.

---

## 7. OAuth flow

### 7.1 Authorization URL (`GoogleCalendarOAuthEndpoints.swift`)

```
https://accounts.google.com/o/oauth2/v2/auth
  ?client_id=<from Info.plist key LeafGoogleCalendarOAuthClientID>
  &redirect_uri=http://127.0.0.1:<ephemeral_port>/callback
  &response_type=code
  &scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.readonly
  &access_type=offline
  &prompt=consent
  &code_challenge=<base64url(SHA256(verifier))>
  &code_challenge_method=S256
  &state=<base64url(32 random bytes)>
  &include_granted_scopes=true
```

### 7.2 Token exchange

```
POST https://oauth2.googleapis.com/token
  Content-Type: application/x-www-form-urlencoded
  Body:
    code=<authorization code>
    client_id=<from Info.plist>
    client_secret=<from Info.plist key LeafGoogleCalendarOAuthClientSecret>
    code_verifier=<PKCE verifier>
    grant_type=authorization_code
    redirect_uri=http://127.0.0.1:<port>/callback
Response (JSON):
  { "access_token": "...", "expires_in": 3920, "refresh_token": "...", "scope": "...", "token_type": "Bearer" }
```

`client_secret` is shipped in the binary (designated-public per Google Desktop OAuth client semantics — research doc §2.3). PKCE is the security boundary.

### 7.3 Identity capture (one extra call post-token)

```
GET https://www.googleapis.com/calendar/v3/users/me/calendarList/primary
Authorization: Bearer <access_token>
```

Response is the primary calendar entry. `.id` is the user's primary email address (plaintext). Stored as `IntegrationRecord.workspaceID = <email>` — same posture as Linear stores workspace UUIDs in SQLCipher (encrypted at rest; never exposed in `presence_state`). Display name from `.summaryOverride ?? .summary`.

**Why plaintext email (not SHA-256 hash):** `external_attendee_count` derivation requires the user's email domain (`workspaceID.split("@")[1]`). Hashing destroys recoverability. Email is private metadata, not a credential — protected by SQLCipher at rest, never in cleartext on disk, never broadcast over relay (presence_state.google_calendar carries `last_synced_at_ms` + activity buckets only, no email).

### 7.4 Connection state machine (mirrors Linear)

```swift
enum ConnectionState {
    case notConnected
    case authorizing
    case waitingForCallback(port: UInt16)
    case exchangingToken
    case fetchingWorkspace
    case connected(workspaceName: String, connectedAt: Date)
    case reconnectNeeded
    case error(String)
}
```

### 7.5 Refresh + reconnect

Mirror `SlackTokenRefresher` pattern:
- **Proactive:** if `integrations.expires_at_ms < now + 5min` at tick start → POST `/token grant_type=refresh_token` → upsert IntegrationRecord with new access_token + new expires_at_ms. Keep refresh_token (Google does not rotate per refresh).
- **Reactive:** on 401 from `events.list` / `calendarList.list` → same refresh, retry once. On second 401 → state=`reconnectNeeded`, clear access_token, keep refresh_token (user can retry refresh, or re-grant).
- **`invalid_grant` from `/token`** (refresh_token revoked / scope changed / 7-day expired in Testing) → state=`reconnectNeeded`, clear access_token + refresh_token. UI prompts user to re-connect.

### 7.6 Pre-launch GCP setup (operational; not part of code)

Per research doc §2.5 checklist:
1. Create Cloud project `leaf-prod`.
2. Enable Google Calendar API in the project.
3. OAuth consent screen → External user type → fill in App name "Leaf", support email, app logo, privacy policy URL (whitepaper-hosted), terms of service URL, authorized domain `gundem.tech`.
4. Add scope: `https://www.googleapis.com/auth/calendar.readonly`.
5. Add up to 100 test users (alpha cohort).
6. Move publishing status → **In production** (required for long-lived refresh tokens; verification pending is fine).
7. Submit brand verification (2-3 days).
8. Submit sensitive scope verification (2-6 weeks).
9. Copy `client_id` + `client_secret` into `Info.plist` keys `LeafGoogleCalendarOAuthClientID` / `LeafGoogleCalendarOAuthClientSecret`.
10. Verify Search Console domain `gundem.tech`.

---

## 8. Collector — `GoogleCalendarCollector.swift`

### 8.1 Tier structure

Single tier — **5-min hot tick only**. No warm / cold tier (syncToken delta covers everything; calendarList sync piggy-backs every 12th tick = 1h).

### 8.2 Tick flow (pseudocode)

```
tick():
  if connectionState != .connected:
    return

  // (1) Token freshness
  refresher.refreshIfDueProactive()  // updates IntegrationRecord in-place
  if connectionState == .reconnectNeeded:
    return

  // (2) calendarList piggy-back (every 12th tick = ~1h)
  if shouldRefreshCalendarList(now):
    let calListDelta = api.calendarListList(syncToken: store.calendarListToken())
    let oldKnown = store.knownCalendars()
    let newKnown = applyDelta(oldKnown, calListDelta).filter { $0.accessRole in [owner, writer, reader] }
    store.upsertKnownCalendars(newKnown)
    store.upsertCalendarListToken(calListDelta.nextSyncToken)
    // Removed calendars: drop their syncToken + tracker rows
    for removed in oldKnown.ids.subtracting(newKnown.ids):
      store.deleteEventsSyncToken(calendarId: removed)
      tracker.deleteByCalendarId(removed)

  // (3) Per-calendar events.list sync (sequential MVP)
  for calendar in store.knownCalendars():
    do:
      let pages = paginate(api.eventsList(calendarId: calendar.id,
                                         syncToken: store.eventsSyncToken(calendar.id)))
      // First-bootstrap path: if no saved syncToken, use:
      //   singleEvents=true, showDeleted=true, timeMin=now-1y, maxResults=2500
      // Subsequent: just syncToken
      if firstPage of bootstrap: store.markBootstrapInProgress(calendar.id)

      for event in pages.allItems:
        if event.eventType in ["fromGmail", "birthday"]: skip (blocklist)
        let payload = mapper.makeObservedPayload(event, calendar)
        emit RawEvent(eventKind: "google_calendar_event_observed", payload: payload)

        if event.eventType in ["focusTime", "outOfOffice", "workingLocation"]:
          if event.status == "cancelled":
            tracker.delete(eventId: event.id)
          else:
            tracker.upsert(eventId, calendarId, iCalUID, eventType, startMs, endMs, upsertedAt: now)

      // Persist token only on terminal page
      if pages.isTerminalPage:
        store.upsertEventsSyncToken(calendar.id, pages.nextSyncToken)
        store.markBootstrapComplete(calendar.id)

    catch 410.fullSyncRequired:
      store.deleteEventsSyncToken(calendar.id)
      tracker.deleteByCalendarId(calendar.id)
      // next tick re-bootstraps THIS calendar
    catch 404 (calendar removed mid-sync):
      // marked as removed in next calendarList tick
      log + continue

  // (4) Tracker scan — emit transitions
  for row in tracker.rowsNeedingStartedEmit(now):
    let kind = transitionKind(eventType: row.eventType, phase: .started)
    emit RawEvent(eventKind: kind, payload: mapper.makeTransitionPayload(row, phase: .started))
    tracker.markStartedEmitted(row.eventId, atMs: now)

  for row in tracker.rowsNeedingEndedEmit(now):  // only focusTime + ooo; workingLocation skipped here
    let kind = transitionKind(eventType: row.eventType, phase: .ended)
    emit RawEvent(eventKind: kind, payload: mapper.makeTransitionPayload(row, phase: .ended))
    tracker.markEndedEmitted(row.eventId, atMs: now)

  // workingLocation: emit _changed once at start_ms, no _ended
  // (handled by tracker.rowsNeedingStartedEmit semantically for wL too,
  //  mapped to _working_location_changed)

  // (5) Cleanup
  tracker.deleteWhere(end_ms < now - 7days)

  // (6) presence_state composite write
  let state: [String: Any] = [
    "known_calendar_count": store.knownCalendars().count,
    "focus_block_active": tracker.hasActiveFocusBlock(now: now),
    "ooo_active": tracker.hasActiveOOO(now: now),
    "working_location": tracker.currentWorkingLocation(now: now) ?? NSNull(),
    "next_meeting_start_ms": <derived from events query, ShareEventTypeKey-gated> ?? NSNull(),
    "last_synced_at_ms": now,
  ]
  PresenceStateWriter.upsert(provider: .googleCalendar, state: state, nowMs: now, in: db)
```

### 8.3 Bootstrap idempotency

- `provider_snapshots.snapshot_json` for `sync_token:events:<calendar_id>` carries `bootstrap_in_progress: bool`.
- Set TRUE on first page of bootstrap-mode events.list.
- Set FALSE only when terminal page reached AND nextSyncToken persisted.
- On process restart, any calendar with `bootstrap_in_progress=true` AND no syncToken → re-bootstrap from scratch; tracker rows for that calendar dropped first.
- Tracker rows from previous partial bootstrap are dropped via `tracker.deleteByCalendarId(...)` before re-bootstrap.

### 8.4 Cursor advance discipline

- `events.list` walk: persist `nextSyncToken` only when terminal page reached.
- If page walk fails mid-stream (network error / 5xx / parse error): do NOT persist token. Next tick retries from previous saved token (full delta replay; idempotent).
- 410 on first page of subsequent tick → wipe THAT calendar's token + tracker rows; re-bootstrap on tick N+1.

### 8.5 Multi-calendar isolation

- Per-calendar `provider_snapshots` row keyed `sync_token:events:<calendar_id>`.
- Per-calendar tracker rows indexed by `calendar_id`.
- 410 on calendar A wipes only A's row + A's tracker rows. Calendars B...N untouched.

### 8.6 Rate budget sanity (research doc §1.6)

- 5 calendars × 1 call/tick × 12 ticks/hr = 60 calls/hr per user. Default 60 QPS quota = headroom 60×3600 / 60 = 3600× headroom.
- 20 calendars × 12/hr = 240 calls/hr — still trivial.
- Bootstrap: 5 calendars × ~10 pages × 1 call = 50 calls one-shot. Negligible.

---

## 9. UI surface

### 9.1 Settings → Connections

New row "Google Calendar" below Linear / GitHub / Slack. Same row template:
- [Connect] / [Reconnect] button (state-driven from `ConnectionState`)
- Badge: not connected / authorizing / connected (`<email>`) / reconnect needed / sync in progress
- "Sync in progress" sub-line while any calendar has `bootstrap_in_progress=true`

### 9.2 Settings → Share Controls (registry-driven)

6 new toggles auto-render via existing `ShareEventTypeRegistry.userFacingTitle` pattern. No per-toggle copy work beyond enum case strings — handled by registry consumers. All default OFF.

Suggested user-facing titles (registry copy):
- `googleCalendarEventObserved` → "Calendar events (title + start/end)"
- `googleCalendarFocusBlockStarted` → "Focus blocks — started"
- `googleCalendarFocusBlockEnded` → "Focus blocks — ended"
- `googleCalendarOOOStarted` → "Out of office — started"
- `googleCalendarOOOEnded` → "Out of office — ended"
- `googleCalendarWorkingLocationChanged` → "Working location changes"

### 9.3 Privacy walkback dashboard (Track-2 D4)

Auto-renders new event_kinds via `ActivityFeedMapper.mapGoogleCalendar`. No bespoke UI work.

### 9.4 No other UI changes

- No Onboarding flow change.
- No new MCP tool surface.
- No new Activity tab work beyond the dispatch mapping.
- No new System Observers entry.

---

## 10. Smoke acceptance criteria (Stage 7)

Author's Mac, real Google account (alpha cohort test user):

| # | Step | Expected |
|---|---|---|
| 1 | Settings → Connections → "Connect Google Calendar" → grant `calendar.readonly` in browser. | `integrations` row created; `ConnectionState=connected(<email>, now)` visible. |
| 2 | Wait ≤5 min. | `provider_snapshots` has `sync_token:events:<id>` row per known calendar + `sync_token:calendar_list` + `known_calendars`. `events` has N `google_calendar_event_observed` rows for past-year visible events. |
| 3 | Create Google focusTime event for `now+2min → now+7min` via web UI. | Within ≤5min after start_ms: `events` row with `google_calendar_focus_block_started` + `auto_decline_mode` + `chat_status`. `presence_state.google_calendar.focus_block_active=true`. |
| 4 | Wait for focus block to end. | Within ≤5min after end_ms: `events` row with `google_calendar_focus_block_ended`. `presence_state.google_calendar.focus_block_active=false`. |
| 5 | Create OOO event ±5min from now. | Same pattern as focus block but `_ooo_started/_ended` + `auto_decline_mode`. |
| 6 | Mark today as homeOffice via Google web UI. | `events` row with `google_calendar_working_location_changed`, `working_location_type="homeOffice"`. `presence_state.google_calendar.working_location="homeOffice"`. |
| 7 | Cancel an existing event. | Next tick: `events` row with `google_calendar_event_observed`, `status="cancelled"`. Tracker row deleted if event was typed. |
| 8 | Subscribe to a shared team calendar (writer access). | Within ≤1h (next calendarList piggy-back): new calendar in `known_calendars`; its events picked up next 5min tick. |
| 9 | Manually corrupt syncToken in DB (simulate 410). | Next tick: `events.list` returns 410; that calendar's syncToken + tracker rows wiped. Tick N+1: re-bootstrap completes; `bootstrap_in_progress` flag toggles. No errors visible in UI. |
| 10 | Wait 1h+ (token TTL ≈ 3920s). | Next tick: proactive refresh fires; `integrations.access_token` rotated; `integrations.connected_at_ms` unchanged. |
| 11 | Privacy walkback grep: `sqlite3 events.sqlite "SELECT payload_json FROM events WHERE payload_json LIKE '%google_calendar%'"` piped through `grep -E '(decline_message\|building_id\|attendee_email\|description\|conference_uri\|location\|customLocation\|hangoutLink)'`. | Zero hits. |
| 12 | All SPM tests green; all 5/5 xcodebuild schemes green. | Pre-existing 2012 baseline + ~60 new = ~2072. |

---

## 11. Testing strategy

### 11.1 Unit tests (`Packages/LeafCore/Tests/LeafCoreTests/`)

| File | Coverage | Approx tests |
|---|---|---|
| `GoogleCalendarEventMapperTests.swift` | Canned JSON fixtures: default event, focusTime, OOO, workingLocation, cancelled instance, recurring instance, event with conferenceData, event with multi-language summary, all-day event, event with maxAttendees=1 truncation. | ~20 |
| `GoogleCalendarTrackerStoreTests.swift` | UPSERT idempotency, started-only emit, ended-only emit, transition idempotency on re-tick, cancelled deletion, multi-calendar isolation, cleanup. | ~10 |
| `GoogleCalendarSyncTokenStoreTests.swift` | First-write, subsequent UPSERT, multi-calendar isolation, 410-wipe-one-calendar, bootstrap flag transitions. | ~8 |
| `GoogleCalendarCollectorTests.swift` | Full tick lifecycle with `StubGoogleCalendarAPIClient` returning canned events.list responses; assert events emitted + presence_state + tracker state. Bootstrap + steady-state + 410 recovery + 404-calendar-removed paths. | ~12 |
| `GoogleCalendarOAuthClientTests.swift` | Token exchange success / failure / refresh / invalid_grant. | ~6 |
| `GoogleCalendarTokenRefresherTests.swift` | Proactive vs reactive refresh; mirror Linear/Slack patterns. | ~5 |
| `GoogleCalendarBlocklistTests.swift` | Skip eventType=fromGmail + birthday confirmed. | ~3 |

### 11.2 Privacy walkbacks (`RelayBodyLeakageTests.swift` extensions)

Sentinel injection per event_kind:
- 7 sentinel kinds: `SECRET-GCAL-DESC-{uuid}`, `SECRET-GCAL-LOC-{uuid}`, `SECRET-GCAL-ATTENDEE-{uuid}`, `SECRET-GCAL-DECLINE-{uuid}`, `SECRET-GCAL-CONF-URI-{uuid}`, `SECRET-GCAL-BUILDING-{uuid}`, `SECRET-GCAL-CUSTOM-LOC-{uuid}`.
- For each of 6 event_kinds: inject sentinel into synthetic Google API response → parse via collector → assert sentinel NOT in events.payload_json + NOT in presence_state.google_calendar.state_json.
- Total: 7 × 6 = **42 walkback assertions**.

### 11.3 Dispatch coverage (Track-4 S4 fence #15)

Test #15 iterates `GoogleCalendarEventKind.allCases`, asserts each rawValue is either:
- in `ActivityFeedMapper.mapGoogleCalendar` switch (matched case returning non-nil), OR
- in `ActivityFeedMapper.skippedKinds` explicit allowlist.

### 11.4 Provider stub

`StubGoogleCalendarAPIClient` conforming to `GoogleCalendarAPIClient` protocol. Returns hand-crafted `EventsListResponse` / `CalendarListResponse` / `TokenResponse` JSON. Mirror Linear's `StubLinearGraphQLProvider` pattern. No network in CI.

### 11.5 No real-Google integration tests in CI

Per author's-Mac smoke discipline (Section 10). Same as Linear/Slack/GitHub.

### 11.6 Test count target

Unit + integration sums:
- Mapper (11.1): ~20
- TrackerStore: ~10
- SyncTokenStore: ~8
- Collector full-lifecycle: ~12
- OAuthClient: ~6
- TokenRefresher: ~5
- Blocklist: ~3
- Walkbacks (11.2): 42 (7 sentinels × 6 kinds)
- DispatchCoverage entries (11.3): 6 (one per kind, counted as one parametrized test)
- **Total: ~112 new tests.**

Baseline 2012 → target **~2124**. (Earlier estimate of "+60" undercounted walkbacks.)

---

## 12. Substrate consumer-grep follow-ups

Step 0 of implementation plan grep for these enums and adapt every consumer:

| Enum | New case | Files to check |
|---|---|---|
| `PresenceStateWriter.Provider` | `.googleCalendar` | Any `switch` on this enum that's exhaustive (no `default`). Found by `grep -rn "case .github\|case .linear\|case .slack" --include="*.swift"`. |
| `IntegrationProvider` (if exists separately) | `.googleCalendar` | Same grep pattern. Found by checking where `IntegrationRecord.provider` is consumed. |
| `CollectorID` (if exists) | `.googleCalendarPolling` | Same pattern. |
| `ShareEventTypeKey` | 6 new cases | Auto-covered by `ShareEventTypeRegistry` consumers; no manual grep beyond DispatchCoverageTests. |

If any exhaustive switch has no `default` clause, the new enum case forces compile errors at all sites. This is **wanted** — surfaces consumers needing per-provider handling. Resolve case-by-case at plan Step 1.

---

## 13. Open issues / follow-ups (post-P4)

- **Multi-account-per-user** (multiple Google accounts on one install) — requires M005 lift (composite-PK `integrations`). Track as v1.1 if any beta user requests.
- **Cross-source dedupe** with EventKit `meeting_state_*` rows — Phase 4.9 Derived Insights via `(iCalUID, start_ms)` join on `events.payload_json`. Index on `payload_json->>'$.i_cal_uid'` may be wanted at scale; defer to Phase 4.9 measurement.
- **`events.watch` push** — v1.1 candidate if real-time calendar transitions become a product priority.
- **OAuth incremental authorization** for adding scopes later — v1.1.
- **Per-attendee external-domain bucket** sensitivity tuning — current MVP definition: `external_attendee_count` = count of attendees whose email domain ≠ user's primary email domain. Domain extracted from `integrations.workspace_id` reverse-lookup of cached primary calendar identity. Edge case: aliases (`+suffix`, multiple domains in a Workspace) deferred to Phase 4.9.

---

## 14. Acceptance criteria (track level, per contract §10)

- All 6 new event_kinds shipped, registered, default-OFF.
- M027 + provider_snapshots usage landed; no other schema changes.
- ShareEventTypeKey registry 152 → 158.
- `RelayBodyLeakageTests` 42 new walkback assertions; pass.
- `DispatchCoverageTests` parity fence #15 extended; pass.
- Smoke (Section 10) on author's Mac: all 12 steps pass.
- 5/5 SPM + xcodebuild schemes green.
- `.claude/shared/current-state.md` updated with P4 closing summary.
- Whitepaper sync per `/sync-docs` for depth-parity ambition (public-safe framing; specific event_kind names + payload field lists stay private per pre-push-leaf checklist).

---

## 15. Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-05-16 | Reuse `Leaf/Integrations/Linear/PKCE.swift` + `LoopbackCallbackListener.swift` in-place; do NOT refactor to `LeafCore/Auth/`. | Verified Slack already reuses Linear's namespace (`SlackOAuthService.swift:18` comment). Adding Google as third consumer of the same files maintains the established pattern with zero refactor risk. |
| 2026-05-16 | Single-tier collector (5-min hot only); calendarList sync piggy-backs every 12th tick. | `syncToken` is a delta-cursor — captures everything in one tier. No separate warm/cold needed. calendarList changes (new subscribed calendar) are sub-hourly tolerable. |
| 2026-05-16 | M027 = single new table (`google_calendar_typed_event_tracker`); syncToken cursors stored in `provider_snapshots` JSON. | OQ-A lock. provider_snapshots is the natural home for opaque-string cursors (M015 designed for exactly this). New table only for time-crossing tracking state which provider_snapshots can't represent per-event. |
| 2026-05-16 | workingLocation = single-shot `_changed` event_kind (no `_started/_ended` pair). | "Working location" is a status snapshot, not a bracketed activity. Implicit transitions via next `_changed` event. |
| 2026-05-16 | Ephemeral port for loopback (Linear=47823 fixed, Slack=47824 fixed — both for historical reasons). | Google has no relay-bounce constraint; ephemeral is more robust if user runs multiple OAuth flows concurrently. `LoopbackCallbackListener` already supports it. |
| 2026-05-16 | `eventType=fromGmail` and `eventType=birthday` blocklisted entirely; do not emit any event_kind. | Both contain auto-extracted PII (Gmail body / Contacts). Privacy floor. |
| 2026-05-16 | Skip `workingLocationProperties.officeLocation.{buildingId,floorId,deskId,label}` in MVP. | Workspace-specific opaque IDs; value uncertain; privacy-conservative posture. Re-evaluate post-MVP if any team requests building-level overlap insights. |
