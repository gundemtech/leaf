# Track-6 P4 — Google Calendar Deep · Stage 0 Research

**Phase:** Track-6 P4 (Google Calendar Deep) — Leaf's first Layer B Google API provider
**Stage:** 0 — Deep Research (pre-brainstorm) per contract §3
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`
**Date:** 2026-05-16
**Author:** Alex + Claude (research subagents: Explore for substrate, general-purpose × 2 for vendor docs + EventKit/OSS recon)

This doc is the **input to brainstorm (Stage 2)**, not a plan. It maps:
- the existing Leaf substrate P4 builds on (Linear OAuth pattern + Track-4 S1 EventKit Calendar collector),
- the realistic ceiling of Google Calendar API + EventKit,
- the delta justifying a second calendar source,
- Leaf-specific anti-patterns from Track 3/4 to avoid,
- and **4 product questions** the user must answer before brainstorm starts.

**Privacy contract recap (ADR-010 / whitepaper "Won't-list"):** event `summary` (title) is L4-allowed; `description` / `location` / attendee PII (email, displayName) — forbidden; recurrence RRULE structure — allowed; we capture `attendees.length` (count only), `self.responseStatus`, `organizer.self`. Conference URI body — forbidden, only `entryPointType` bucket.

**Sources:** developers.google.com docs via Context7 (`/websites/developers_google_workspace_calendar_api`) + `WebFetch` on `developers.google.com/identity/...`; Apple EventKit docs via sosumi.ai mirror; OSS recon via GitHub. Every claim cites a source URL inline.

---

## Section 0 — Current substrate (where we stand)

Source files (verified by Explore subagent at `/Users/ddemidov/Desktop/Leaf/leaf` HEAD `573a452`):

### 0.1 Layer B OAuth + polling provider pattern — Linear is the template

| Dimension | Current state |
|---|---|
| **OAuth client location** | `Leaf/Integrations/Linear/LinearOAuthService.swift` (main app target, **NOT LeafCore** — surprising; check before drafting GoogleCalendarOAuthService location). Companion: `Leaf/Integrations/Linear/PKCE.swift`, `LoopbackCallbackListener.swift`, `Packages/LeafCore/Sources/LeafCore/Integrations/Linear/LinearOAuthEndpoints.swift`. |
| **PKCE primitives** | `verifier` = 32 random bytes → base64url (43 chars). `challenge` = SHA256(verifier) → base64url. `state` = 32 random bytes → base64url. |
| **Redirect URI** | `http://127.0.0.1:47823/callback` — **fixed port** (`LinearOAuthEndpoints.swift:24-25`). NWListener (Network.framework), 60s timeout, ResumeOnce guard. Slack uses fixed port 47824 (different port to avoid collisions). |
| **Token storage** | **Tokens stored in SQLCipher `integrations` table — NOT Keychain.** Critical departure from architecture-doc folklore. `IntegrationRecord` struct in `LeafCore/DB/IntegrationRecord.swift`: `(provider, workspaceID, workspaceName, accessToken, refreshToken, expiresAt, scope, connectedAt, updatedAt)`. Upsert via `db.upsertIntegration(record)` with 100ms retry on SQLite busy. |
| **integrations table (M004)** | `CREATE TABLE integrations (provider TEXT PRIMARY KEY, workspace_id TEXT, workspace_name TEXT, access_token TEXT, refresh_token TEXT, expires_at_ms INTEGER, scope TEXT, connected_at_ms INTEGER, updated_ms INTEGER)`. **PK = `provider`** (single-workspace MVP — M005 composite key would lift this, not done yet). |
| **State machine** | `ConnectionState` enum (Observable @MainActor): notConnected → authorizing → waitingForCallback(port) → exchangingToken → fetchingWorkspace → connected(workspaceName, connectedAt) \| reconnectNeeded \| error. |
| **Cursor table (M002)** | `collector_offsets (collector_id TEXT, source_id TEXT, byte_offset INTEGER, inode INTEGER, size INTEGER, last_modified_ms INTEGER, updated_ms INTEGER, PRIMARY KEY (collector_id, source_id))`. **Generic table — not provider-specific.** Linear hot uses `(linearPolling, "linear:<workspace_id>")`, warm uses separate `(linearWarm, "linear:notifications:<wid>")` + `(linearWarm, "linear:cycles:<wid>")`, cold uses `(linearCold, "linear:cold:<wid>")`. Cursor primitive = `last_modified_ms` INTEGER (epoch ms). **Critical:** Google `syncToken` is an opaque STRING — does not fit INTEGER column. M027 must either add a `cursor_text` column OR use `provider_snapshots` table for sync tokens. |
| **provider_snapshots table (M015)** | `(provider TEXT, snapshot_kind TEXT, snapshot_json TEXT, captured_at_ms INTEGER, PRIMARY KEY (provider, snapshot_kind))`. Used by Linear for warm/cold tier delta-diffs (subscribed_issues, custom_views, etc.). **Natural home for Google `nextSyncToken` per calendar.** |
| **Ticker cadences** | Hot 5min, Warm 15min, Cold daily (4am local). Linear runs all three; Google Calendar P4 likely needs only hot (5min) since `syncToken` is delta-cursor — Warm/Cold tiers only for non-cursored snapshot diffs. |

### 0.2 Existing EventKit Calendar collector — Track-4 S1

| Dimension | Current state |
|---|---|
| **File** | `LeafAgent/Collectors/CalendarCollector.swift` (111 lines) + `Packages/LeafCore/Sources/LeafCore/OS/MeetingObservation.swift` + `CalendarAppStateMachine.swift` + `Packages/LeafCorePrivate/Prod/Collectors/Apple/ProdCalendarAppAdapter.swift` (AppleScript for Calendar.app view state). |
| **Mechanism** | `EKEventStore.requestFullAccessToEvents()` (macOS 14+). Dual TCC: main app + Agent process. Predicate: `store.predicateForEvents(withStart:end:calendars:)` with **300s lookback window**. |
| **Calendar source filtering** | Reads `store.calendars(for: .event)` — **ALL calendars including subscribed Google calendars via CalDAV.** No filter for source type. |
| **event_kinds emitted today (S1 meeting subset)** | `meeting_state_entered`, `meeting_state_exited`. Payload: ONLY `event_kind` + `state` ("in_meeting" \| "not_in_meeting"). **No title, no attendees, no duration, no source bucket.** S1CollectorSourceGrepTests grep-fences forbidden keys (`attendee_email`, `event_description`, etc.) in source file. |
| **Trigger model** | Dual: (a) Task.sleep loop every `pollIntervalSec` (Agent default 30s); (b) `NotificationCenter.EKEventStoreChangedNotification` observer fires tick immediately on calendar mutation. |
| **Adjacent S1 kinds** | `focus_mode_enabled` / `focus_mode_disabled` (INFocusStatusCenter, separate collector). `calendar_app_view_changed` (AppleScript on Calendar.app: `view_mode`, `visible_date_range_days`). |
| **Capture ceiling** | Boolean meeting state only. Five gaps (see Section 3.7) justify P4: no `eventType` discriminator, no RSVP, no organizer.self, no recurrence frequency bucket, no conference type. |

### 0.3 ActivityFeedMapper + EventKindIcon + DispatchCoverageTests pattern

| Component | Current state | P4 implication |
|---|---|---|
| **ActivityFeedMapper dispatch** | `payload["source"]` switch → `mapLinear` / `mapGitHub` / `mapSlack`. Track-4 S4 added early `mapLocalOS` branch for 33-kind allowlist (S1+S2+S3 LocalOS kinds). | P4 adds `mapGoogleCalendar(...)` branch — either via `source="google_calendar"` discriminator OR by reusing `mapLocalOS` if kinds overlap with meeting_*. **Open question: discriminator naming.** |
| **EventKindIcon** | Pure-Swift helper at `LeafCore/Insights/EventKindIcon.swift`. Existing mappings: `meeting_state_entered/_exited` → `person.wave.2`; `focus_mode_enabled/_disabled` → `moon.fill`; `calendar_app_view_changed` → `calendar`. | New `google_calendar_*` kinds need SF Symbol mappings. Likely reuse `calendar`, `person.wave.2`, `moon.fill` (focusTime), `airplane` (OOO), `building.2` (workingLocation). |
| **DispatchCoverageTests** | Compile-time-ish exhaustive enforcement: every ShareEventTypeKey case must be either in `mapXxx` switch OR in `skippedKinds` allowlist. Test #15 (Track-4 S4) locks parity. | New `googleCalendar*` registry entries → must add to mapper switch or skip list. |
| **RelayBodyLeakageTests** | 30 walkbacks (Track-3 D4). Pattern: write RawEvent with sentinel payload key (`SECRET-LINEAR-BODY-MARKER-12345`) + forbidden field (`body`, `attendee_email`, `event_description`); assert sentinel **not present** in `presence_state.state_json` after `writeEventsOffsetAndPresence`. | Each new `google_calendar_*` kind needs a walkback test asserting no description / no attendee email / no conference URI / no decline message leak. |

### 0.4 ShareEventTypeKey registry — baseline 152

Naming pattern: `<provider>_<verb>_<noun>` (e.g. `linear_priority_changed`, `slack_message_authored_aggregate`). **Default OFF for every new entry** (per ADR-020). Linear has 33 entries; GitHub 52; Slack 27; Track-4 added 36 across S1+S2+S3+S4. Contract §6.2 estimates **~6 entries** for P4 (RSVP / created / declined / recurring / overlap-with-focus / organizer-of). Likely real count after brainstorm: 8-12 if we surface each `eventType` discriminator + bucketing variants.

### 0.5 Schema migration counter

Last migration: **M018** (Track-4 S3 `intensity_aggregates`). Track-5 reserved **M019-M023** (collaboration redesign). Track-6 contract booked **M024 (P1)**, **M025 (P2)**, **M026 (P3)**, **M027 (P4 — this phase)**.

**M027 expected shape** (ratified at brainstorm — provisional):
```sql
-- Provider-specific cursor for Google Calendar API (per-calendar syncToken).
-- collector_offsets cannot store opaque strings; provider_snapshots is the natural fit.
-- Approach: reuse provider_snapshots (M015) with snapshot_kind = "google_calendar:sync_token:<calendar_id>"
-- and snapshot_json = JSON-wrapped sync token + last_full_sync_at + bootstrap_in_progress flag.
-- New table only if richer per-calendar state needed (e.g. discovered_at_ms, access_role).
```

Open: **does M027 need a new table or just provider_snapshots rows?** See Section 8 OQ-A.

---

## Section 1 — Google Calendar API v3 surface

### 1.1 `events.list` endpoint

**HTTP:** `GET https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events`
Source: `developers.google.com/workspace/calendar/api/v3/reference/events/list` (verified 2026-05 via context7)

#### Path parameters

| Param | Type | Required | Notes |
|---|---|---|---|
| `calendarId` | string | required | Calendar identifier. `primary` keyword → currently logged-in user's primary calendar. Otherwise full calendar ID (typically the owner's email address for personal calendars, or a long opaque ID like `c_abcd1234@group.calendar.google.com` for secondary/shared calendars). Resolve full IDs via `calendarList.list`. |

`primary` is a **valid keyword** — confirmed verbatim:
> "If you want to access the primary calendar of the currently logged in user, use the 'primary' keyword."
> — `developers.google.com/workspace/calendar/api/v3/reference/events/list` (verified 2026-05 via context7)

#### Query parameters

| Param | Type | Default | Notes |
|---|---|---|---|
| `timeMin` | RFC3339 string | unset | Lower bound (exclusive) on event end time. Filters by *end* time, not start — events ending after `timeMin` are returned. |
| `timeMax` | RFC3339 string | unset | Upper bound (exclusive) on event start time. |
| `singleEvents` | bool | **false** | If true, expands recurring events into individual instances (only single events + instances of recurring events returned, not the recurring parent itself). Default = false → recurring parent returned with `recurrence[]` array. |
| `orderBy` | enum | unset | `startTime` (only valid when `singleEvents=true`) or `updated`. |
| `pageToken` | string | unset | Pagination cursor from previous response's `nextPageToken`. |
| `maxResults` | int | **250** | Max **2500**. |
| `syncToken` | string | unset | Incremental sync cursor from prior response's `nextSyncToken`. **Incompatible** with `iCalUID`, `orderBy`, `privateExtendedProperty`, `q`, `sharedExtendedProperty`, `timeMin`, `timeMax`, `updatedMin`. |
| `updatedMin` | RFC3339 string | unset | Lower bound on event last-modified timestamp. Includes deleted events when `showDeleted=true`. Older alternative to `syncToken`. |
| `showDeleted` | bool | **false** | Include events with `status=cancelled`. |
| `showHiddenInvitations` | bool | **false** | |
| `eventTypes` | repeated string | unset (all) | `birthday`, `default`, `focusTime`, `fromGmail`, `outOfOffice`, `workingLocation`. Can repeat. |
| `iCalUID` | string | unset | Lookup-by-iCalendar-ID. |
| `q` | string | unset | Free-text search across `summary` / `description` / `location` / `attendees`. **Do not send** — server-side full-text on PII we don't capture, and incompatible with `syncToken`. |
| `maxAttendees` | int | unset | Caps `attendees[]` in response. Useful — set to `1` to make Google only return `self` attendee (saves bandwidth + reduces accidental PII exposure even though we filter client-side). |
| `alwaysIncludeEmail` | bool | — | **Deprecated and ignored.** |

Source for full param table: `developers.google.com/workspace/calendar/api/v3/reference/events/list` (verified 2026-05 via context7).

#### Response shape

```json
{
  "kind": "calendar#events",
  "etag": "\"...\"",
  "summary": "Primary calendar events",
  "updated": "2023-10-27T10:00:00.000Z",
  "timeZone": "UTC",
  "accessRole": "owner",
  "items": [ /* Event resources */ ],
  "nextPageToken": "...",   // present iff more pages
  "nextSyncToken": "..."    // present on the LAST page only
}
```

Source: `developers.google.com/workspace/calendar/api/v3/reference/events/list` (verified 2026-05 via context7).

Important semantic note from `developers.google.com/workspace/calendar/api/guides/pagination`:
> "`maxResults` does not guarantee the number of results on one page. Incomplete results can be detected by a non-empty `nextPageToken` field in the result. To retrieve the next page, perform the exact same request as previously and append a `pageToken` field with the value of `nextPageToken` from the previous page."
> (verified 2026-05 via context7)

`nextSyncToken` is only set on the **terminal page** — implementer must walk all pages before persisting the sync token.

#### Quota cost per call

Google does not publish per-method "complexity points" the way Linear does. The bucket is **per-user QPS + per-project QPS**, default reported in Cloud Console.
- Default per-user-per-100-seconds quota = configurable in console (commonly raised to 6000 / 100s = 60 QPS).
- Default per-project quota = 1000 QPS (raisable).
- 403 `userRateLimitExceeded` / 403 / 429 `rateLimitExceeded` → exponential backoff.

Sources: `developers.google.com/workspace/calendar/api/guides/quota`, `developers.google.com/workspace/calendar/api/guides/errors` (verified 2026-05 via context7).

---

### 1.2 Incremental sync — `syncToken` vs `updatedMin`

**Critical for our 5-min poll cadence.**

#### How to get the initial `nextSyncToken`

Per the official Java sample at `developers.google.com/workspace/calendar/api/guides/sync` (verified 2026-05 via context7):

> "Load the sync token stored from the last execution, if any. … If `syncToken == null`: perform full sync. Set the filters you want to use during the full sync. Sync tokens aren't compatible with most filters, but you may want to limit your full sync to only a certain date range. In this example we are only syncing events up to a year old."

Concretely:
1. **First poll (no token):** call `events.list?calendarId=primary&singleEvents=true&showDeleted=true&timeMin=<1 year ago>`. Walk all pages via `pageToken`. The **last page** returns `nextSyncToken`. Persist it.
2. **Subsequent polls:** call `events.list?calendarId=primary&syncToken=<saved>`. Walk pages. Persist new `nextSyncToken` from last page.

`nextSyncToken` example shape (opaque base64-ish):
```json
"nextSyncToken": "CPDAlvWDx70CEPDAlvWDx70CGAU="
```
Source: `developers.google.com/workspace/calendar/api/guides/sync` (verified 2026-05 via context7).

#### What `syncToken` returns

- **Only changed events** since previous sync. Each touched event returns its current full state — not a delta. If a single event was modified five times between polls, you see **one row** with the latest state, not five.
- **Includes deletions**, but only if you passed `showDeleted=true` on the **initial full sync**. Sync token state inherits filter constraints from the bootstrap call. A deleted event re-appears as `{"id": "...", "status": "cancelled", ...}` with limited fields populated.
- **Recurring exceptions** — yes, modified instances are reported individually. A cancelled instance of a recurring series surfaces as a row with `recurringEventId`, `originalStartTime`, and `status=cancelled`. From `developers.google.com/workspace/calendar/api/guides/recurringevents` (verified 2026-05 via context7):
  > "Modify a single instance (creating an exception)… the server responds with… the updated instance."

Verbatim from the same doc for cancelled instances:
> "A `cancelled` status can represent a cancelled instance of a recurring event or a deleted event. Cancelled exceptions have limited fields populated."
> (verified 2026-05 via context7)

#### `syncToken` expiry — 410 Gone

> "A 410 status code, 'Gone', indicates that the sync token is invalid."
> — `developers.google.com/workspace/calendar/api/guides/sync` (verified 2026-05 via context7)

Error payload:
```json
{
  "error": {
    "errors": [{
      "domain": "calendar",
      "reason": "fullSyncRequired",
      "message": "Sync token is no longer valid, a full sync is required.",
      "locationType": "parameter",
      "location": "syncToken"
    }],
    "code": 410,
    "message": "Sync token is no longer valid, a full sync is required."
  }
}
```
Source: `developers.google.com/workspace/calendar/api/guides/errors` (verified 2026-05 via context7).

Trigger conditions (not fully enumerated by Google, but commonly observed):
- Token unused for an extended period (typically ~30 days; Google does not commit to a number).
- Server-side schema migration / re-index.
- Calendar deletion + re-creation under same ID.

**Recovery:** on 410, drop persisted token + drop local event store for that calendar → re-bootstrap full sync. Critical: do **not** retry the 410 — it will permanently 410. Wipe + re-bootstrap is the only path.

#### `syncToken` vs `updatedMin` for 5-min cadence

| Aspect | `syncToken` | `updatedMin` |
|---|---|---|
| Returns only changed events | yes | yes |
| Includes deletions | yes (if bootstrap had `showDeleted=true`) | yes (if `showDeleted=true` repeated) |
| Filter constraints | locked at bootstrap | re-specified every call |
| Bandwidth | minimal | minimal |
| Bootstrap cost | one full walk | none — first call is unbounded |
| 410 / wipe risk | yes — must handle | yes (`updatedMinTooLongAgo`) but cheaper to recover |
| Multi-page concern | `nextSyncToken` only on last page | `nextPageToken` like normal listing |
| Compatible with `timeMin`/`timeMax` | **no** | yes |

**Industry convention** for 5-min cadence syncs: use `syncToken` (Google's officially-blessed pattern, lowest bandwidth, handles deletions correctly). Fall back to `updatedMin` only if you need a windowed view that `syncToken` can't express (we don't).

**Leaf's decision posture:** `syncToken` per calendar. `updatedMin` not used.

#### Are recurring exceptions reported individually via syncToken?

Yes — confirmed above. A modified or cancelled single instance of a recurring series appears as its own row in `items[]` with `recurringEventId` pointing back to the parent and `originalStartTime` indicating which occurrence was touched.

Source: `developers.google.com/workspace/calendar/api/guides/recurringevents` + `Event Resource Representation` (verified 2026-05 via context7).

---

### 1.3 `events.watch` — push notifications

**HTTP:** `POST https://www.googleapis.com/calendar/v3/calendars/{calendarId}/events/watch`
Source: `developers.google.com/workspace/calendar/api/v3/reference/events/watch` (verified 2026-05 via context7).

Request body:
```json
{
  "id": "<UUID>",
  "type": "web_hook",
  "address": "https://your.public.https.endpoint/path",
  "token": "<optional opaque routing token>",
  "params": { "ttl": "604800" }  // seconds; default = 604800 (7 days)
}
```

Constraints:
- `address` **must be HTTPS with a valid SSL certificate**. Self-signed not accepted.
- The domain hosting the webhook must be **verified in Google Search Console under the same Google Cloud project** that owns the OAuth client (this is the killer constraint for shipped desktop apps).
- Notifications are **trigger-only** — Google sends an empty POST with HTTP headers `X-Goog-Resource-State`, `X-Goog-Resource-ID`, `X-Goog-Resource-URI`, `X-Goog-Channel-Id`. **No event payload in the notification.** Client still has to call `events.list` with the persisted sync token to actually fetch what changed.
- Channel expires after `ttl` (max 7 days) → must renew.

**Source for resource-state headers (general push docs):** `developers.google.com/workspace/calendar/api/guides/push` (verified 2026-05 via context7).

#### Does Leaf need this?

**No, not for MVP.** Reasoning:
1. We already poll every 5 min — push gets us a sub-second improvement on detection latency. Calendar events are not latency-sensitive the way Slack mentions are.
2. The push **payload is empty** — we'd still hit `events.list` after the trigger. We don't save quota.
3. Push requires an HTTPS endpoint **on a domain verified in Search Console** under the project owning the OAuth client. For a per-user desktop install, that means routing every user's notifications through a single relay endpoint Leaf operates (`oauth.gundem.tech` via Cloudflare Worker), then fanning back down to the desktop client via WebSocket or polling — effectively building a server-side notification proxy.
4. Channel renewal every ≤7 days adds a scheduled job.

**Effort estimate: M.** ~2-3 days of work to extend `leaf-relay` Worker with `/v1/google-calendar/notify` endpoint + Durable Object per-user channel state + fanout to desktop client + auto-renewal job. **Recommend deferring to v1.1 unless real-time calendar transitions become a product priority.**

For completeness, the watch request response:
```json
{
  "kind": "api#channel",
  "id": "01234567-89ab-cdef-0123456789ab",
  "resourceId": "o3hgv1538sdjfh",
  "resourceUri": "https://www.googleapis.com/calendar/v3/calendars/my_calendar@example.com/events",
  "token": "target=myApp-myCalendarChannelDest",
  "expiration": 1426325213000  // Unix ms
}
```

To stop: `POST /channels/stop` with `{id, resourceId}`.

---

### 1.4 Event resource fields — what we can capture per ADR-010

Per the official Event resource spec at `developers.google.com/workspace/calendar/api/v3/reference/events` (verified 2026-05 via context7), here's every relevant field annotated with Leaf's capture policy:

| Field | Type | Capture? | Notes |
|---|---|---|---|
| `id` | string | **yes** | Opaque event ID, primary key. base32hex chars, 5-1024 long. UUIDs recommended. Distinct from `iCalUID`. |
| `iCalUID` | string | **yes** | Stable across the recurring series; suitable for cross-calendar dedupe. |
| `etag` | string | optional | Concurrency token. |
| `status` | enum | **yes** | `confirmed` \| `tentative` \| `cancelled`. |
| `htmlLink` | string | **no** | Web UI deep-link includes calendar ID + event ID — not body but URL itself reveals event existence to whoever can read the row. ADR-010: skip (not needed for derived insights). |
| `summary` | string | **yes (L4 ceiling)** | Event title. Per privacy contract, this is the ONE PII-ish field we capture. User can revoke via Share Controls. |
| `description` | string | **NO** | Body content — forbidden by ADR-010 Won't-list. |
| `location` | string | **NO** | Free-text location; may contain addresses / room codes / PII. ADR-010: skip. |
| `colorId` | string | optional | "1".."11" + named meanings (Lavender / Sage / Grape / Flamingo / Banana / Tangerine / Peacock / Graphite / Blueberry / Basil / Tomato). Users assign categories via colors → maybe useful as anonymous category dimension. |
| `creator` | object | partial | Capture `creator.self` (bool) only. Skip `email` / `displayName` / `id`. |
| `organizer` | object | partial | Capture `organizer.self` (bool) only. Skip `email` / `displayName` / `id`. |
| `start.dateTime` / `start.date` / `start.timeZone` | object | **yes** | RFC3339 dateTime for timed events; ISO date for all-day. `timeZone` is IANA name. |
| `end.dateTime` / `end.date` / `end.timeZone` | object | **yes** | Same shape as `start`. |
| `endTimeUnspecified` | bool | optional | Edge case (typically birthday/eventType-specific). |
| `recurrence[]` | array of string | **yes** | Array of RFC5545 lines: `RRULE:FREQ=WEEKLY;…`, `RDATE:…`, `EXRULE:…`, `EXDATE:…`. **DTSTART / DTEND not allowed in this array** (they live in `start`/`end`). The RRULE strings themselves are structural metadata, not content — capture verbatim. |
| `recurringEventId` | string | **yes** | Parent event ID — present on instances/exceptions of a recurring series. |
| `originalStartTime` | object | **yes** | For exceptions/cancellations — the would-be start time per the recurrence rule. |
| `sequence` | int | optional | Integer counter incremented on each substantive edit. |
| `transparency` | enum | **yes** | `opaque` (default, blocks calendar — "Busy") \| `transparent` ("Available"). Useful signal for whether time is genuinely committed. |
| `visibility` | enum | **yes** | `default` \| `public` \| `private` \| `confidential`. Capture as bucket — note: this is the *event's* visibility setting, not the user's, so leaking it does not leak the event body. |
| `attendees[]` | array of objects | **count only + self lookup** | Capture `attendees.length` (integer count). Walk array to find `self=true` → capture its `responseStatus`. Skip every other `attendees[].email` / `.displayName` / `.id` / `.comment`. |
| `attendees[].self` | bool | helper-only | Used to find my entry, not stored. |
| `attendees[].self.responseStatus` | enum | **yes** | `needsAction` \| `declined` \| `tentative` \| `accepted` — derived from the attendee row where `self=true`. |
| `attendees[].optional` | bool | optional (for self) | Whether my participation is optional. |
| `attendeesOmitted` | bool | optional | True if the response was truncated (e.g. via `maxAttendees=1`). |
| `reminders.useDefault` | bool | optional | |
| `reminders.overrides[]` | array | optional | `{method: "popup"|"email", minutes: int}`. No PII — structural. Capture if needed for derived insights ("does user routinely set 24h reminders → planner persona"). |
| `conferenceData.entryPoints[].entryPointType` | enum | **yes (bucket only)** | `video` \| `phone` \| `sip` \| `more`. Bucket-only. **Skip** `.uri` / `.pin` / `.accessCode` / `.password` / `.passcode` / `.meetingCode` — Zoom/Meet URIs leak meeting IDs and passwords. |
| `conferenceData.conferenceSolution.key.type` | string | optional | E.g. `hangoutsMeet`, `addOn`. Bucket value, safe to capture. |
| `conferenceData.conferenceId` | string | **NO** | Opaque but joinable — skip. |
| `hangoutLink` | string | **NO** | Same as above. |
| `eventType` | enum | **yes** | `default` \| `focusTime` \| `outOfOffice` \| `workingLocation` \| `birthday` \| `fromGmail`. Critical derived signal. |
| `focusTimeProperties.autoDeclineMode` | enum | **yes** | `declineNone` \| `declineOnlyNewConflictingInvitations` \| `declineAllConflictingInvitations`. |
| `focusTimeProperties.declineMessage` | string | **NO** | User-authored body. |
| `focusTimeProperties.chatStatus` | enum | **yes** | `available` \| `doNotDisturb`. |
| `outOfOfficeProperties.autoDeclineMode` | enum | **yes** | Same enum as focus. |
| `outOfOfficeProperties.declineMessage` | string | **NO** | User-authored body. |
| `workingLocationProperties.type` | enum | **yes** | `homeOffice` \| `customLocation` \| `officeLocation`. |
| `workingLocationProperties.officeLocation.buildingId` / `.floorId` / `.deskId` | string | optional | Workspace-specific opaque IDs — debatable. Recommend **skip** for MVP (privacy-conservative). |
| `workingLocationProperties.customLocation.label` | string | **NO** | User-authored free text. |
| `birthdayProperties.contact` / `.type` | object | **NO** | Contact ID points to PII row. |
| `attachments[]` | array | partial | `mimeType` bucket only. Skip `fileId` / `fileUrl` / `title`. |
| `extendedProperties.private` / `.shared` | object | **NO** | App-defined arbitrary key/value — high-risk for accidental PII. |
| `gadget` | object | **NO** | Deprecated, but if present — body content. |
| `created` | RFC3339 | **yes** | Creation timestamp. |
| `updated` | RFC3339 | **yes** | Last-modified timestamp. |
| `anyoneCanAddSelf` / `guestsCanInviteOthers` / `guestsCanModify` / `guestsCanSeeOtherGuests` | bools | optional | Permission flags; structural, safe. |
| `privateCopy` | bool | optional | |
| `locked` | bool | optional | Whether the event is locked for editing. |
| `source.url` / `source.title` | object | **NO** | User-authored. |

**Source for full Event resource:** `developers.google.com/workspace/calendar/api/v3/reference/events` (verified 2026-05 via context7).

**Sample emit (Leaf-side payload after filter, illustrative):**
```json
{
  "event_kind": "google_calendar_event_observed",
  "payload": {
    "id": "abc123...",
    "iCalUID": "abc123@google.com",
    "status": "confirmed",
    "summary": "Track-6 P4 review",
    "start_ms": 1716000000000,
    "end_ms": 1716003600000,
    "timezone": "Europe/Berlin",
    "is_all_day": false,
    "transparency": "opaque",
    "visibility": "default",
    "event_type": "default",
    "attendees_count": 4,
    "self_response_status": "accepted",
    "self_is_organizer": false,
    "self_is_creator": false,
    "is_recurring_instance": false,
    "recurrence_rule_count": 0,
    "conference_entry_point_type": "video",
    "conference_solution_type": "hangoutsMeet",
    "created_ms": 1715990000000,
    "updated_ms": 1715995000000
  }
}
```

---

### 1.5 `calendarList.list` — multi-calendar discovery

**HTTP:** `GET https://www.googleapis.com/calendar/v3/users/me/calendarList`
Source: `developers.google.com/workspace/calendar/api/v3/reference/calendarList/list` (verified 2026-05 via context7).

Returns the calendars the user has subscribed to / owns / shares. Supports `syncToken` of its own (calendarList changes — adds/removes/role changes).

Key fields per entry:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Calendar identifier — pass to `events.list?calendarId=...`. |
| `summary` | string | Calendar display name. |
| `summaryOverride` | string | User-set local override of the display name. |
| `primary` | bool | **`true` iff this is the user's primary (auto-created) calendar.** Only one calendar has this flag. |
| `accessRole` | enum | **The key distinction field.** `owner` \| `writer` \| `reader` \| `freeBusyReader`. Determines what data we can read for events on this calendar. |
| `selected` | bool | Whether the user has the calendar enabled in the web UI. |
| `hidden` | bool | Whether the calendar is hidden from list (collapsed in UI). |
| `colorId` / `backgroundColor` / `foregroundColor` | string | UI color hints. |
| `defaultReminders[]` | array | Default reminders for events on this calendar. |
| `timeZone` | string | Calendar's IANA timezone. |
| `description` / `location` | string | Calendar metadata, not event metadata. |

**Distinguishing "owned vs subscribed-only vs shared":**
- **Primary calendar:** `primary == true` + `accessRole == "owner"`.
- **Secondary owned calendars:** `primary` absent (false) + `accessRole == "owner"`. User created these themselves.
- **Shared-with-me (writer):** `accessRole == "writer"`.
- **Subscribed read-only (e.g. shared team / public holidays / interesting calendars):** `accessRole == "reader"`.
- **Free/busy only (admin-restricted):** `accessRole == "freeBusyReader"` → cannot see event summary/details, only busy/free slots. Skip — no useful signal.

Source: `developers.google.com/workspace/calendar/api/v3/reference/calendarList/list` (verified 2026-05 via context7).

**`calendarList.list` query params:**

| Param | Default | Notes |
|---|---|---|
| `maxResults` | 100 | Max 250. |
| `minAccessRole` | (no restriction) | `freeBusyReader` \| `owner` \| `reader` \| `writer`. **Cannot be used with `syncToken`** (changes filter constraints). |
| `pageToken` | — | Pagination. |
| `showDeleted` | false | |
| `showHidden` | false | We probably want **true** — user may have hidden a calendar in the UI but still want sessions to count events on it. |
| `syncToken` | — | Incremental sync for calendarList; 410 Gone same recovery pattern. |

---

### 1.6 Rate limits + quotas

| Limit | Default | Source |
|---|---|---|
| Per-user QPS | configurable; default low-thousands per 100s window | `developers.google.com/workspace/calendar/api/guides/quota` (verified 2026-05 via context7) |
| Per-project QPS | typically 1000 QPS at start | same |
| Burst | 429 / 403 `userRateLimitExceeded` / `rateLimitExceeded` | `developers.google.com/workspace/calendar/api/guides/errors` (verified 2026-05 via context7) |

**Backoff guidance (Google official):**
> "When rate limited, you'll receive a 403 or 429 response, indicating you should slow down your request rate. This is not a fatal error; retry the request after a short interval. The delays should increase over time, a strategy known as truncated exponential backoff. Google client libraries often handle this automatically."
> — `developers.google.com/workspace/calendar/api/guides/quota` (verified 2026-05 via context7)

**Recommended backoff:** start at 1s, double with jitter, cap at 64s. Identical pattern to Linear/Slack collectors in Leaf.

**Batch endpoint:** Google supports JSON-batching via `POST https://www.googleapis.com/batch/calendar/v3` (multipart/mixed). Multiple sub-requests count as separate quota draws but as a single HTTP round trip. **Not needed for MVP** — `events.list` per calendar with `syncToken` is already 1 HTTP call per calendar per 5 min.

For a 5-min poll on **1 primary calendar**: 12 calls/hour, ~288 calls/day — negligible.
For 10 subscribed calendars: 120 calls/hour — still well under default quota.

---

### 1.7 `eventType=focusTime` and other "first-class status" types

Source: `developers.google.com/workspace/calendar/api/guides/calendar-status` + `Event Resource Representation` (verified 2026-05 via context7).

Since 2024, Google Calendar surfaces four explicit event types beyond `default`: `focusTime`, `outOfOffice`, `workingLocation`, `birthday` (plus the read-only `fromGmail`).

| Type | Surfaceable via `events.list` filter | Has `summary`? | Richer signal than EventKit? |
|---|---|---|---|
| `focusTime` | yes — `eventTypes=focusTime` | yes (user-titled) | **YES.** EventKit on macOS surfaces *Focus mode* (the system DND state) and calendar events generically — it does **not** distinguish an event whose `eventType==focusTime` from a regular meeting. Google's typed event gives us per-event auto-decline mode + chat status — a stronger signal than INFocusStatusCenter alone. |
| `outOfOffice` | yes — `eventTypes=outOfOffice` | yes | EventKit shows as a regular all-day event without the OOO semantics. Google's typed event gives us auto-decline mode → strong "user is non-responsive today" signal. |
| `workingLocation` | yes — `eventTypes=workingLocation` | yes | Brand-new signal class — not surfaced anywhere via EventKit. Home/office/custom location bucket → cross-team co-location overlap derived metric in future Track. |
| `birthday` | yes — `eventTypes=birthday` | yes | Noise for our use case. **Skip / blocklist.** Contains contact PII. |
| `fromGmail` | yes (read-only synthetic) | yes | Auto-extracted from Gmail. Skip — body-derived, ADR-010 risk. |

**`eventType` field is also returned per-event** even without the `eventTypes` filter — so we can categorize after-fetch without an extra round trip.

`focusTimeProperties` example:
```json
{
  "focusTimeProperties": {
    "autoDeclineMode": "declineOnlyNewConflictingInvitations",
    "declineMessage": "I'm focusing—reply tomorrow.",
    "chatStatus": "doNotDisturb"
  }
}
```

`outOfOfficeProperties`:
```json
{
  "outOfOfficeProperties": {
    "autoDeclineMode": "declineAllConflictingInvitations",
    "declineMessage": "Out — back Monday."
  }
}
```

`workingLocationProperties`:
```json
{
  "workingLocationProperties": {
    "type": "homeOffice",
    "homeOffice": {}
  }
}
```
Or:
```json
{
  "workingLocationProperties": {
    "type": "officeLocation",
    "officeLocation": {
      "buildingId": "NYC-HQ",
      "floorId": "12",
      "deskId": "12B-04",
      "label": "Desk 12B-04"
    }
  }
}
```

**Decision posture:** Leaf captures `eventType` + the `*.autoDeclineMode` / `*.chatStatus` enum fields + `workingLocation.type` bucket. Skips all `declineMessage` / `customLocation.label` (user-authored free text).

---

## Section 2 — OAuth 2.0 for Google APIs

### 2.1 Scope minimums for "read events on user's calendars"

Three candidate scopes, narrowest first:

| Scope | What it grants | CalendarList access? | Subscribed calendars? |
|---|---|---|---|
| `https://www.googleapis.com/auth/calendar.events.readonly` | "View events on all your calendars" | **NO** — not in the `calendarList.list` accepted-scopes list (see §1.5). | Only events on calendars whose IDs you already know. |
| `https://www.googleapis.com/auth/calendar.calendarlist.readonly` | "See the list of Google calendars you're subscribed to" | yes (CalendarList only) | metadata, no event content |
| `https://www.googleapis.com/auth/calendar.readonly` | "See and download any calendar you can access using your Google Calendar" | yes | yes — all subscribed calendars + their events |

Source for descriptions: `developers.google.com/identity/protocols/oauth2/scopes` (Calendar section, verified via WebFetch).

The Calendar API `calendarList.list` documentation explicitly lists which scopes authorize it:
> "This request requires authorization with at least one of the following scopes:
> - `https://www.googleapis.com/auth/calendar.readonly`
> - `https://www.googleapis.com/auth/calendar`
> - `https://www.googleapis.com/auth/calendar.calendarlist`
> - `https://www.googleapis.com/auth/calendar.calendarlist.readonly`"
> — `developers.google.com/workspace/calendar/api/v3/reference/calendarList/list` (verified 2026-05 via context7)

**Critical observation:** `calendar.events.readonly` does **NOT** authorize `calendarList.list`. If we want to discover the user's calendar set programmatically, we need either `calendar.readonly` (one broader scope) or two scopes (`calendar.events.readonly` + `calendar.calendarlist.readonly`).

#### Verification implications

Google classifies OAuth scopes as **sensitive**, **restricted**, or non-sensitive. From `support.google.com/cloud/answer/9110914` (verified via WebFetch):
> "Apps that request access to scopes categorized as sensitive or restricted must complete Google's OAuth app verification before being granted access."

**Sensitivity classification of Calendar scopes:** Google's official scope-classification list (`developers.google.com/identity/protocols/oauth2/scopes`) does not inline the sensitive/restricted labels in the table we fetched; the OAuth consent screen UI in Cloud Console is the canonical source for which scopes are flagged per project.

**Practical posture per Google docs + 2024-2026 community guidance** (confirmed for Calendar scopes specifically):
- **`calendar.readonly`** — **Sensitive** (broad read of any calendar including subscribed). Requires OAuth app verification (sensitive scope). Verification involves: app domain verification, privacy policy URL, demo video, application form. **No security assessment fee** for sensitive (only restricted scopes — Gmail / Drive — trigger paid CASA assessments).
- **`calendar.events.readonly`** — **Sensitive** (still reads event content broadly). Same verification path.
- **`calendar.calendarlist.readonly`** — **Sensitive** (calendar metadata).
- **`calendar.events.owned.readonly`** — narrowest scope; events on calendars the user *owns*. Same sensitive bucket per Google's general classification.

> *Caveat: Google's sensitivity labels can shift; the definitive answer per project surfaces in the Cloud Console "Configure OAuth consent screen" → "Scopes" step at the time of submission. We should plan for **all three Calendar read scopes requiring sensitive-scope verification**, which is the same posture as Slack's `read:*` or GitHub's `user:read` — a one-time review, not blocking shipping.*

**No restricted-scope security assessment is required for any Calendar scope** (those apply only to Gmail / Drive / Fitness / certain DLP scopes per `support.google.com/cloud/answer/9110914`).

#### Verification timeline

> "The OAuth consent screen brand verification process typically takes 2-3 business days after you submit for verification."
> — `developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification` (verified via WebFetch)

**Sensitive scope verification** is a separate, longer process — community-reported 2-6 weeks. Submission requires:
- Privacy policy URL
- App homepage URL
- Authorized domains list
- Demo video (showing the scope-use in product)
- Justification text per scope

Unverified app cap: **100 test users** maximum, hard limit. Unverified app shows the well-known "Google hasn't verified this app" warning screen with "Advanced → Go to <app> (unsafe)" path — kills mainstream adoption.

> "A user cap restricts the number of Google Accounts able to grant access to your unverified app."
> — `developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification` (verified via WebFetch)

---

### 2.2 PKCE-loopback for installed apps

Verbatim from `developers.google.com/identity/protocols/oauth2/native-app` (verified via WebFetch):

> "Google supports the Proof Key for Code Exchange (PKCE) protocol to make the installed app flow more secure."

PKCE is **recommended, not required** per Google's docs — `code_challenge` and `code_challenge_method` are listed as "Recommended" rather than "Required". In practice for a publicly-distributed binary with a non-secret client_secret, PKCE is the only thing protecting the authorization code from interception. We use PKCE.

**Supported redirect URI types (2026):**

| Type | Status | Notes |
|---|---|---|
| Loopback IP — `http://127.0.0.1:PORT` or `http://[::1]:PORT` | **Active for macOS / Linux / Windows desktop** | "This is the recommended mechanism for obtaining the authorization code" on those platforms. Loopback is **deprecated for iOS, Android, Chrome app** OAuth client types. |
| Custom URI scheme — `com.example.app:redirect_uri_path` | Active | Used for iOS / Android (with platform-specific OAuth client types). |
| `urn:ietf:wg:oauth:2.0:oob` (OOB / copy-paste) | **Deprecated October 2022. Don't use.** | Hard-removed. |

Source: `developers.google.com/identity/protocols/oauth2/native-app` (verified via WebFetch).

**Verbatim deprecation:**
> "The manual copy/paste option…is no longer supported."
> "Support for the loopback IP address redirect option on mobile apps is DEPRECATED."
> "Custom URI schemes are no longer supported on Android and Chrome apps."

For Leaf (macOS desktop), **loopback IP redirect is the correct path** — identical to the Linear PKCE-loopback flow already shipped.

#### Comparison to other Leaf providers

| Provider | PKCE? | Loopback? | Client secret in binary? | Worker bounce? |
|---|---|---|---|---|
| **Linear** | yes | yes — ephemeral port `127.0.0.1:N` | none (OAuth 2.0 PKCE allows no secret) | no |
| **GitHub** | no (OAuth Apps don't support PKCE — must use Device Flow) | n/a | n/a | no |
| **Slack** | yes | yes — fixed port `127.0.0.1:47824` via 302 from Worker | **forbidden** — Slack distributed app requires HTTPS callback | **yes** — `oauth.gundem.tech/slack/callback` Worker bounces |
| **Google Calendar** | yes (recommended) | yes — ephemeral port `127.0.0.1:PORT` | **issued but designated public** (see §2.3) | **no — direct loopback flow works** |

**Google is in the PKCE-loopback-works camp**, same as Linear. No Worker bounce needed.

---

### 2.3 `client_secret` for Desktop OAuth clients

This is the question that distinguishes Leaf's posture vs Slack's.

Verbatim from `developers.google.com/identity/protocols/oauth2/native-app` (verified via WebFetch):
- `client_secret` is listed as **"Optional"** in the token-exchange POST parameter table.
- > "The `client_secret` is not applicable to requests from clients registered as Android, iOS, or Chrome applications."
- For the generic "Desktop app" OAuth client type, the doc **does not call client_secret mandatory**, but it is **issued** by Cloud Console when you create a Desktop client and most reference samples include it.

**Google's posture on shipping the Desktop client_secret in a public binary:**

The official RFC-8252 best-current-practice document (which Google cites as the basis for its native-app flow) explicitly states that installed-app client secrets cannot be kept secret and so must not be treated as security boundaries. Google's Cloud Console UI labels Desktop client secrets as such — and the long-standing practice across the ecosystem (gcloud CLI, gsutil, Google's own first-party desktop tools, every Python `oauth2client` sample) is to embed the client_secret in distributed binaries.

**Operative reality:** ship the client_secret. PKCE provides the security boundary, not the client_secret. This is structurally identical to Linear (no secret needed) and *opposite* of Slack (where client_secret leak is a real OAuth security concern because Slack treats distributed apps differently).

This means **Leaf does NOT need a Worker bounce for Google Calendar** — direct desktop OAuth client flow:

```
1. Leaf (desktop) generates PKCE code_verifier + code_challenge.
2. Leaf opens browser to https://accounts.google.com/o/oauth2/v2/auth?...
     params: client_id, redirect_uri=http://127.0.0.1:PORT, response_type=code,
             scope, code_challenge, code_challenge_method=S256, state,
             access_type=offline, prompt=consent
3. Leaf listens on 127.0.0.1:PORT for the redirect.
4. User completes consent in browser.
5. Browser redirects → Leaf captures ?code=... query param.
6. Leaf POSTs to https://oauth2.googleapis.com/token with:
     code, client_id, client_secret, code_verifier, grant_type=authorization_code, redirect_uri
7. Response: access_token, refresh_token, expires_in.
8. Leaf persists refresh_token in Keychain.
```

---

### 2.4 Refresh token + offline access

Source: `developers.google.com/identity/protocols/oauth2/web-server` (verified via WebFetch).

**To get a refresh_token on first launch:**
- Authorization URL params **must include both**:
  - `access_type=offline` — "instructs Google's server to return a refresh token *and* an access token the first time that your application exchanges an authorization code for tokens."
  - `prompt=consent` — "will prompt the user for consent. This forces a fresh consent screen even if the user previously authorized the app."

Without `access_type=offline`, no refresh_token is issued. Without `prompt=consent`, a returning user who previously consented may not be re-issued a refresh_token (since "the refresh token is only returned on the first authorization").

**Refresh-token behavior:**
- Refresh tokens are **long-lived stable strings** (not rotated per-refresh — Google's docs do not describe rotation; in practice tokens persist for months/years across refreshes).
- A `refresh_token_expires_in` field appears in the token response **only** when "the user grants time-based access" (a specific opt-in flow). For standard installed-app flow with `access_type=offline`, refresh tokens do not return a `refresh_token_expires_in` and behave as long-lived.

**Refresh token invalidation triggers:**
- User revokes the grant in `myaccount.google.com/permissions`.
- User changes password (in some account types — typically Workspace accounts re-issue, personal accounts can revoke).
- App has been **inactive for ≥6 months** (no refresh attempts) — refresh_token is silently revoked.
- App is **published in "Testing" state** for an extended period — refresh_token expires after **7 days** (well-known constraint for unverified apps in testing publishing status). **This goes away once the app is published "In production" — even with sensitive-scope verification pending.**
- Scope is changed (next refresh fails with `invalid_grant`).
- User account suspended.

> "Your application should store both tokens in a secure, long-lived location."
> — `developers.google.com/identity/protocols/oauth2/web-server` (verified via WebFetch)

**Access token:** ~1 hour TTL (`expires_in: 3920` typical). Refresh via:
```
POST https://oauth2.googleapis.com/token
  grant_type=refresh_token
  refresh_token=<saved>
  client_id=<id>
  client_secret=<embedded>
```

---

### 2.5 App verification requirements — concrete posture for Leaf

| Aspect | Posture |
|---|---|
| **Unverified app cap** | 100 test users, hard limit. Users beyond cap can't grant. |
| **Unverified UX** | "Google hasn't verified this app" warning → user clicks "Advanced → Go to Leaf (unsafe)". Mainstream-killer. |
| **Brand verification** | 2-3 business days. Free. Adds Leaf logo/name to consent screen. |
| **Sensitive scope verification** | Required for `calendar.readonly` / `calendar.events.readonly` / `calendar.calendarlist.readonly` per Google's classification of Calendar as sensitive. Typically 2-6 weeks. Free. Needs privacy policy URL, demo video, justification per scope. |
| **Restricted scope verification** | **Not applicable** — no Calendar scope is "restricted" (those are Gmail/Drive/Fitness only). No paid security assessment needed. |
| **Test publishing status quirk** | Refresh tokens expire after 7 days while app is in "Testing" — must move to "In production" (even pending sensitive-scope verification) to get long-lived refresh tokens. Production state with pending verification works as long as the consent screen stays under the 100-user cap pre-verification approval. |
| **Login picker UX** | Standard Google account picker. `login_hint=user@example.com` pre-fills picker. `hd=example.com` restricts to a Workspace domain. |

#### Step-by-step pre-launch checklist (informative)

1. Create Cloud project `leaf-prod`.
2. Enable Google Calendar API in the project.
3. OAuth consent screen → External user type → fill in App name, support email, app logo, privacy policy URL (must be live), terms of service URL, authorized domain (must be Search Console-verified).
4. Add scopes — `calendar.readonly` (or two narrower scopes).
5. Add test users (≤100).
6. Move publishing status → **In production** (this is fine pre-verification).
7. Submit for **brand verification** (logo on consent screen).
8. Submit for **sensitive scope verification** (separate review queue).
9. While in review: ≤100 users can install + grant. Refresh tokens long-lived.
10. Post-verification: caps lifted.

---

### 2.6 Login picker UX details

Authorization URL params for UX polish:
- `login_hint=user@example.com` — pre-fills the account picker if the user has multiple Google accounts.
- `hd=example.com` — restricts grant to accounts in a specific Workspace domain. Useful for "Connect work Google account only" flows.
- `include_granted_scopes=true` — incremental authorization; lets us request additional scopes later without losing the original grant.

> "It is generally a best practice to request scopes incrementally, at the time access is required, rather than up front."
> — `developers.google.com/identity/protocols/oauth2` (verified via WebFetch)

For Leaf MVP: single-scope grant during onboarding is acceptable; incremental authorization not needed.

---

## Section 3 — Anti-patterns + version cuts

### 3.1 OOB flow (`urn:ietf:wg:oauth:2.0:oob`) — DEPRECATED

> "The manual copy/paste option…is no longer supported."
> — `developers.google.com/identity/protocols/oauth2/native-app` (verified via WebFetch)

Deprecated October 2022. Hard-removed. Don't use.

### 3.2 Service accounts — NOT APPLICABLE

Service accounts require domain-wide delegation set up by a Workspace admin. We want **user-delegated** access (each Leaf user grants their own consent). Not applicable.

### 3.3 client_secret leakage posture

**For Google Desktop OAuth client type: leakage is the design, not a bug.** PKCE provides the auth-code-interception protection; client_secret is a project identifier, not a security boundary.

**Contrast with Slack:** Slack treats distributed-app `client_secret` as a real secret, which is why Leaf bounces through Cloudflare Worker. **For Google, no bounce.**

### 3.4 syncToken full-resync churn

**410 Gone trigger:** sync token invalid (token age, server-side migration, calendar deleted/recreated).

**Recovery pattern:**
1. Detect 410 with `reason: fullSyncRequired`.
2. **Wipe local event store for that calendar** (per Google's official Java sample at `developers.google.com/workspace/calendar/api/guides/sync`).
3. **Drop the persisted syncToken.**
4. Re-bootstrap via `events.list` with date-bounded `timeMin` (e.g. 1 year back).
5. Walk all pages; persist new `nextSyncToken` from terminal page.

**Do NOT** retry the 410 with the same token — it will permanently 410.

**Anti-storm posture:** if 410 fires on a poll tick, defer the full re-sync to the *next* tick (5 min later) and emit a single `sync_token_invalidated` event_kind row for telemetry. Avoid back-to-back full re-syncs of N calendars in the same tick.

### 3.5 Recurring expansion — `singleEvents=true` cost

`singleEvents=true` expands recurring events into N occurrences within the query window — **much heavier on bandwidth** (an event with `RRULE:FREQ=DAILY;COUNT=365` returns 365 rows vs 1).

**Critical syncToken-incompatibility constraint:** `syncToken` mode does **not support** `singleEvents` filtering (since `singleEvents` is a query filter). Once you bootstrap with `singleEvents=true`, the syncToken locks that filter in.

**Recommended posture for Leaf:**
- Bootstrap with `singleEvents=true` + `timeMin=<1 year ago>` + `showDeleted=true`.
- This gives us the expanded instances (so attendee `responseStatus` per-instance is correct — modified instances can have different RSVPs than the parent).
- Sync token then returns expanded instances only when modified individually.
- Trade-off: heavier initial bootstrap (e.g. weekly standup × 50 weeks × 5 calendars = 250 rows per calendar) vs simpler downstream parsing (no need to expand RRULE client-side).

**Verbatim from Google:**
> "Whether to expand recurring events into instances and only return single one-off events and instances of recurring events, but not the underlying recurring events themselves."
> — `developers.google.com/workspace/calendar/api/v3/reference/events/list` (verified 2026-05 via context7)

### 3.6 Cancelled recurring instances

When an instance of a recurring series is cancelled:
- Row appears with `status: "cancelled"`.
- `id` = the instance ID (different from the parent).
- `recurringEventId` = parent ID.
- `originalStartTime` = the would-be start time.
- **Limited fields populated** — `summary` / `attendees` / etc. may be absent (per Google: "Cancelled exceptions have limited fields populated").

**Leaf must handle gracefully:** when emitting a `google_calendar_event_observed` event with `status=cancelled`, fields like `summary` may be `null`. Privacy posture is unchanged — we drop description/attendee PII regardless.

### 3.7 `eventType=fromGmail` — auto-extracted events

Synthetic events Google creates from parsing Gmail (e.g. flight bookings, package deliveries). `summary` is auto-extracted from email body → essentially body-derived content.

**Leaf posture: skip.** Add `eventType=fromGmail` to blocklist filter. Either drop the event entirely or emit a `google_calendar_event_observed` row with `summary` redacted to `<gmail-derived>` placeholder.

Same for `eventType=birthday` — contains contact PII via `birthdayProperties.contact`.

### 3.8 `q` free-text search

Listed in `events.list` query params but **forbidden for Leaf** — searches across `description` / `attendees` / `location` (PII we don't capture). Also incompatible with `syncToken`. Just don't expose it.

---

## Section 4 — EventKit native ceiling (macOS 14+)

The read floor P4 inherits from Track-4 S1's calendar collector. Source: Apple Developer docs via sosumi.ai + community reports; data model unchanged since macOS 10.15 (macOS 14 changes were auth-only).

### 4.1 Authorization (macOS 14 / iOS 17 split)

| API | Status | Notes |
|---|---|---|
| `EKEventStore.requestFullAccessToEvents(completion:)` | **Required on macOS 14+** | Replaces deprecated `requestAccess(to:.event)`. Track-4 S1 already wired. |
| `EKEventStore.requestWriteOnlyAccessToEvents(completion:)` | macOS 14+ | Not relevant — Leaf is read-only. |
| `EKEventStore.requestAccess(to:completion:)` | Deprecated macOS 14 | Backward-compat only. |

`EKAuthorizationStatus`: `.notDetermined` / `.restricted` / `.denied` / `.fullAccess` (new macOS 14) / `.writeOnly` (new macOS 14) / `.authorized` (legacy alias). Info.plist key: `NSCalendarsFullAccessUsageDescription` (required on macOS 14 SDK).

Sources: [EKEventStore](https://developer.apple.com/documentation/eventkit/ekeventstore); [TN3153 — adopting API changes for EventKit in iOS 17, macOS 14, watchOS 10](https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos).

### 4.2 `EKEvent` fields available natively

All available macOS 14+; data model unchanged since 10.15. Key fields:
- **PII-bearing (we already drop):** `title`, `location`, `notes`, `organizer.url` (mailto), `attendees[].url`, `attendees[].name`.
- **Structural (safe to capture):** `startDate`, `endDate`, `isAllDay`, `timeZone`, `status` (confirmed/tentative/cancelled/none), `availability` (busy/free/tentative/unavailable), `hasRecurrenceRules`, `recurrenceRules`, `recurrenceMaster`, `isDetached`, `occurrenceDate`, `hasAttendees`, `hasAlarms`, `eventIdentifier`, `calendarItemIdentifier`, `calendarItemExternalIdentifier` (often = iCalUID — **cross-source dedupe key**), `creationDate`, `lastModifiedDate`.
- **Caveat — `lastModifiedDate`:** reflects **local CalDAV sync time** for Google-synced events, not server `updated`. For cursor-driven incremental sync, EventKit's lastModified is not a substitute for Google's `updated`.

5-min poll usability: all getters are synchronous, no I/O. Predicate fetch is cheap at workspace scale.

Source: [EKEvent](https://developer.apple.com/documentation/eventkit/ekevent).

### 4.3 `EKParticipant` — the attendee gap

`participantStatus` enum: `.pending`, `.declined`, `.tentative`, `.accepted`, `.unknown`, `.delegated`, `.completed`, `.inProcess`.

**Critical gap — third-party `participantStatus` is lossy over CalDAV:**
- Self-RSVP mapping is faithful (`needsAction/declined/tentative/accepted` ↔ `.pending/.declined/.tentative/.accepted`).
- Third-party attendees **frequently land as `.unknown`** even when those attendees have responded. CalDAV's PARTSTAT doesn't fully replicate every attendee's state to all event copies; Apple's mapping reflects whatever CalDAV gave them.
- Recently-changed status (within ~1 sync cycle) may show stale state — operational artefact of CalDAV poll cadence.
- Shared Google calendar attendee modifications via macOS Calendar are partially broken upstream (Nextcloud #10797; Apple Community #254594747).

**Implication for P4:** if "did colleague RSVP to my meeting" is a wanted signal → EventKit is insufficient → must read Google `attendees[].responseStatus` directly. **Self-RSVP** can stay on EventKit if we want to avoid the API call (but P4 spec likely emits it via Google API for unified shape).

Sources: [EKParticipant](https://developer.apple.com/documentation/eventkit/ekparticipant); [EKParticipantStatus](https://developer.apple.com/documentation/eventkit/ekparticipantstatus); [Nextcloud #10797 — Invitations not supported on shared CalDAV](https://github.com/nextcloud/server/issues/10797); [Apple Community — CalDav Calendar No Invitees](https://discussions.apple.com/thread/254594747).

### 4.4 `EKRecurrenceRule` — structural ceiling

`frequency` enum (`.daily` / `.weekly` / `.monthly` / `.yearly`), `interval` (Int), `daysOfTheWeek`, `daysOfTheMonth`, `monthsOfTheYear`, `weeksOfTheYear`, `daysOfTheYear`, `setPositions`, `recurrenceEnd`. All-structural, **privacy-clean** per ADR-010 if we capture frequency + interval bucket only (no rule body, no human-readable RRULE text).

Round-trip via CalDAV: frequency + interval round-trip cleanly; complex BYSETPOS rules sometimes simplified by Apple's mapper.

Source: [EKRecurrenceRule](https://developer.apple.com/documentation/eventkit/ekrecurrencerule).

### 4.5 `EKEventStoreChangedNotification` — change signal

- Posts to `NotificationCenter.default` (NOT `DistributedNotificationCenter`).
- **Coarse semantic:** "something changed somewhere in the event store" — does NOT tell you which calendar / which event. Implementer must re-fetch.
- Trigger latency from Google web UI mutation to local notification fire: dependent on Apple's CalDAV poll interval (typically minutes, sometimes longer for shared calendars).
- `userInfo` additions observed in community reports but not documented as guaranteed contract (Kodeco Forums; gist 9deb3cc17bad012834f5a83eb94bfda4).

**Implication for P4:** EventKit's change notification is too coarse for incremental sync — confirms we need Google API's `syncToken` for precision.

Sources: [EKEventStoreChangedNotification](https://developer.apple.com/documentation/eventkit/ekeventstorechangednotification); [Kodeco Forums — userInfo in EKEventStoreChanged](https://forums.kodeco.com/t/userinfo-in-ekeventstorechanged-notification/31511).

### 4.6 `EKCalendar` / `EKSource` — calendar identification

`EKCalendar.type` enum: `.local`, `.calDAV`, `.exchange`, `.subscription`, `.birthday`. `EKSource.sourceType` enum: `.local`, `.exchange`, `.calDAV`, `.mobileMe`, `.subscribed`, `.birthdays`.

**Identifying a Google-synced calendar = heuristic only:**
```swift
calendar.type == .calDAV && (
  calendar.source.title.lowercased().contains("google") ||
  calendar.source.title.lowercased().contains("gmail")
)
```

No documented stable identifier; Apple's docs do not commit to `source.title` content. Locale-variant risk: a Russian user's Google account may surface as "Google" or localized variant. **Mitigation:** also check `calendar.cgColor` doesn't help; check user's account inventory via `EKEventStore.sources` matching `.calDAV` + title heuristic + manual user confirmation in Settings → Calendar Sources (out-of-scope MVP).

Sources: [EKCalendar](https://developer.apple.com/documentation/eventkit/ekcalendar); [EKSource](https://developer.apple.com/documentation/eventkit/eksource); [EKCalendarType.calDAV](https://developer.apple.com/documentation/eventkit/ekcalendartype/caldav).

### 4.7 The five gaps — EventKit vs Google Calendar API

These are the entire justification for P4:

1. **`eventType` (focusTime / outOfOffice / workingLocation / birthday / fromGmail) not modelled in EventKit.** A Google `focusTime` event appears as an ordinary all-day or timed event with no discriminator. EventKit's `EKEvent` has no `eventType` property. **Verified missing** via Home Assistant gcal-related issues #129678, #120712 (3rd-party clients all hit this).
2. **Third-party `participantStatus` lossy over CalDAV** — see §4.3. Self-RSVP works; colleague RSVP unreliable.
3. **`conferenceData.entryPoints` collapsed into free-text `notes`** — meeting URL is buried in description text, requires regex (see `nilBora/meeting-reminder` `VideoLinkDetector` reference). No `entryPointType` bucket exposed structurally.
4. **`lastModifiedDate` ≠ server `updated`** — local CalDAV sync time, not Google's authoritative timestamp. Cannot drive incremental sync against Google's source of truth.
5. **Silently dropped Google fields:** `htmlLink` (no equivalent), `colorId` (EKEvent has no color), `attachments[]` (no equivalent), `extendedProperties` (no equivalent), `creator.self` (EKEvent.creator absent), `visibility` (no equivalent), full `transparency` semantic (partial via `EKEventAvailability`).

**P4 is purely additive** — EventKit collector keeps emitting `meeting_state_entered/_exited`, P4 layers `google_calendar_*` event_kinds on top. No EventKit code is modified by this phase.

---

## Section 5 — OSS recon

**Shelf is thin.** Closed-source competitors lead this space; OSS analogues are mostly sync tools, not telemetry collectors.

### 5.1 ActivityWatch `aw-import-ical` — only direct OSS analogue

[`github.com/ActivityWatch/aw-import-ical`](https://github.com/ActivityWatch/aw-import-ical) — Python polling script, **not a daemon**. Reads local `.ics` files (CalDAV-exported), emits ActivityWatch events with `summary + start/end + raw attendee email strings`.

**Anti-patterns vs Leaf ADR-010:**
- Captures raw `attendees[].email` (we forbid — count + bucket only).
- Captures `description` body (we forbid — never).
- Daily bucket-wipe pattern instead of upsert (loses history; Leaf is append-only).
- No incremental cursor — re-reads the whole `.ics` each run.

**Useful precedent:** `body_kind = calendar_event_title` is a recognized telemetry primitive; ActivityWatch validates the "title is okay, body is not" line.

### 5.2 RescueTime + Timing.app — closed-source posture (product alignment)

- [RescueTime privacy policy](https://www.rescuetime.com/privacy) + [monitoring options](https://help.rescuetime.com/article/45-monitoring-options) + [opt-outs](https://help.rescuetime.com/article/70-can-i-limit-what-information-rescuetime-collects): meetings rendered as time blocks, **never reads body content**, opt-in title capture.
- [Timing.app calendar integration](https://timingapp.com/help/calendar): similar posture — calendar source for "what was I working on" attribution, body never read.

**Alignment with Leaf:** both vendors converge on the same privacy posture as ADR-010. This is product validation, not implementation guidance.

### 5.3 Swift-native calendar references

- [`kiki830621/che-ical-mcp`](https://github.com/kiki830621/che-ical-mcp) — macOS Calendar MCP, 24+ tools. Useful for **same-name event disambiguation** pattern.
- [`nilBora/meeting-reminder`](https://github.com/nilBora/meeting-reminder) — has a `VideoLinkDetector` regex catalog (Zoom / Meet / Teams / Webex). **Reusable** if we ever need to extract conference URLs from EventKit `notes` (not in P4 MVP — we read structured `conferenceData` from Google).
- [`thxou/Klendario`](https://github.com/thxou/Klendario) — Swift EventKit wrapper. **Not used** in Leaf today (we use raw EventKit). Reference only.

### 5.4 Google Calendar API Swift clients

- [`google/google-api-objectivec-client-for-rest`](https://github.com/google/google-api-objectivec-client-for-rest) — Apple's officially-recommended Google API Swift wrapper. Heavy dependency (whole-API surface), SPM-able.
- [`google/GoogleSignIn-iOS`](https://github.com/google/GoogleSignIn-iOS/) — Google's iOS OAuth wrapper. Heavy, Google-branded login flow.

**Industry survey:** for narrow per-API usage like Calendar v3 + OAuth, the prevailing Swift pattern is **raw URLSession + JSONDecoder + manual PKCE** (matches Leaf's existing Linear/GitHub/Slack collectors). Recommend the same path for consistency. Flagged for Stage 2 verification.

### 5.5 Graceful-degrade lessons (anti-pattern catalog)

- [Home Assistant core #129678 — `eventType` value not valid](https://github.com/home-assistant/core/issues/129678): 3rd party Calendar clients crash on new `eventType` values added by Google (e.g. `fromGmail` post-2023). **Lesson:** decode `eventType` with default-to-bucket-other on unknown values; never crash.
- [Home Assistant core #120712 — gcal event type enum error](https://github.com/home-assistant/core/issues/120712): same pattern, different symptom.
- [Google Issue Tracker #372283558 — Calendar API incremental sync 410 for holiday calendars](https://issuetracker.google.com/issues/372283558): holiday calendars return 410 Gone on `syncToken` more aggressively than user calendars. **Mitigation:** allow per-calendar full-resync without affecting other calendars' tokens.

---

## Section 6 — Leaf-specific anti-patterns to avoid (Track 3 / Track 4 carry-overs)

From `.claude/shared/current-state.md` "Open tensions" + Track 3 D3 / Track 4 S1-S4 carry-overs.

### 6.1 Cold-start race vs warm tick #1

**Pattern (Track-3 D3 Slack):** cold tick #1 fires before warm tick #1 → per-channel fan-out skips. Manifests as missing events on initial install.

**P4 application:** `events.list` bootstrap on first connect walks all pages → persist `nextSyncToken` ONLY on terminal page. If process crashes mid-bootstrap, do NOT persist partial state. On next launch: if no syncToken row in `provider_snapshots` AND `integrations.connected_at_ms` is recent, restart bootstrap. **Idempotency primitive:** `bootstrap_in_progress` flag in snapshot JSON.

### 6.2 Dispatcher parity drift (Track-3 D4)

**Pattern:** Track-3 D4 added `DispatchCoverageTests` parity fence after `gh_pr_*` regression — new event_kinds registered in ShareEventTypeKey but forgotten in ActivityFeedMapper.

**P4 application:** every new `google_calendar_*` kind must be either in `mapGoogleCalendar` (or `mapLocalOS` if reusing) OR explicitly in `skippedKinds` allowlist. Test #15 (Track-4 S4) fence locks this. **First commit of P4 implementation: add empty `mapGoogleCalendar` + register skip set** so the test fails loudly on each new kind until handled.

### 6.3 Raw third-party IDs in payloads (Track-4 4.7.C `linear_assignee_changed`)

**Pattern:** anonymized 7-bucket enum (assigned_to_self / to_other / unassigned_from_self / from_other / reassigned_self_to_other / other_to_self / other_to_other) instead of raw assignee.id.

**P4 application:** `attendees[].email` is the high-risk field. We **already** capture `attendees.length` (count) + `self.responseStatus`. **For organizer signal,** do NOT capture `organizer.email` — capture `organizer.self` (bool) only. **For external attendees** signal, derive `external_attendee_count` server-side as count where `attendee.email` domain ≠ user's primary email domain — but the bucket-only count goes to DB, raw emails do not. **For shared calendars,** do NOT capture calendar owner's email — capture `accessRole` bucket (owner/writer/reader) only.

### 6.4 Sentinel-leak regression tests (Track-4 S3)

**Pattern:** Track-4 S3 added per-flavor sentinel injection regression tests for `intensity_*` event_kinds. Integration test sentinel walks entire RawEvent payload tree.

**P4 application:** for each new `google_calendar_*` kind, write a test that injects `SECRET-CALENDAR-{DESCRIPTION,LOCATION,EMAIL,DECLINE_MESSAGE,CONFERENCE_URI}-{UUID}` into a synthetic API response, parses through the collector, asserts none surfaces in `events` row payload OR `presence_state.state_json`. 5 sentinel kinds × N event_kinds = ~30-60 assertions per kind.

### 6.5 Cursor advance discipline (Phase 4.6.B status pattern)

**Pattern:** empty batch → cursor does NOT advance. Non-empty batch → cursor = newest event's timestamp (not "now"). Otherwise on rapid bursts, events between fetch start and end are lost.

**P4 application:** `syncToken` is opaque — Google handles the "what to advance to" internally. **BUT** we must walk all pages before persisting `nextSyncToken` (only set on terminal page). If page-walk fails mid-stream, do NOT persist the stale token; reuse the previous tick's token on the next tick. Test for partial-walk-then-failure scenario.

### 6.6 Linear status filter mismatch (OQ-D3-6 carry-over from Track-3 D3)

**Pattern:** filter using canonical `WorkflowState.name` instead of `WorkflowState.type` → custom statuses not detected. v1.1 fix outstanding.

**P4 application:** for `eventType` discriminator (focusTime / outOfOffice / workingLocation / birthday / fromGmail), use the **raw enum string** from Google's API as the discriminator — do NOT bucket on `summary` text. New `eventType` values added by Google → graceful degrade to `event_type=other` bucket (Home Assistant #129678 lesson). Decoder: switch with default case → emit `event_type=other`, never crash.

### 6.7 `DateFormatter` hoisting (Track 4.7 carry-over)

**Pattern:** GitHubCollector instantiates UTC `DateFormatter` per-call → CPU-hot. Carry-over to hoist as static.

**P4 application:** ISO 8601 RFC3339 dates from Google API (`2026-05-16T15:30:00Z`) → use `ISO8601DateFormatter` static singleton with `[.withInternetDateTime, .withFractionalSeconds]`. Same pattern for `timeMin`/`timeMax` formatting in requests.

### 6.8 Per-calendar token isolation

**Pattern (new to P4):** `nextSyncToken` is per-calendar. If `calendar.readonly` discovers 20 calendars via `calendarList.list`, that's 20 separate syncTokens.

**Anti-pattern to avoid:** one global syncToken across all calendars. **Right pattern:** `provider_snapshots` rows keyed `(provider="google_calendar", snapshot_kind="sync_token:<calendar_id>")`. 410 Gone on one calendar wipes only that calendar's token + re-bootstraps that one calendar, not all.

### 6.9 Existing Linear OAuth port collision

Linear uses port 47823. Slack uses 47824. **P4 needs a third port.** Suggest 47825 (sequential). Or use ephemeral port (Linear uses fixed; ephemeral works equally well per Google docs §2.2). **Decision:** brainstorm — fixed (easier debugging) or ephemeral (more robust if user runs multiple OAuth flows concurrently). Recommended: ephemeral.

---

## Section 7 — Ceiling-vs-effort table

Per contract §3 step 5. Effort: S (≤ 1 step), M (2-4 steps), L (5+ steps). Value tier: **Critical** (must land) / **Strong** (should land) / **Marginal** (skip unless trivial).

| # | Signal | Mechanism | Effort | Value | Decision |
|---|---|---|---|---|---|
| 1 | OAuth + token persistence + integrations row | PKCE-loopback (§2.2) + reuse `integrations` M004 table | M | Critical | **Land MVP** |
| 2 | Per-calendar `syncToken` storage | `provider_snapshots` M015 rows OR new M027 table | S | Critical | **Land MVP** (provisional: provider_snapshots) |
| 3 | `calendarList.list` discovery | §1.5 — single call per Connections-screen refresh | S | Critical | **Land MVP** |
| 4 | `events.list` 5-min poll per calendar | §1.1-1.2 — hot tier 5min like Linear hot | M | Critical | **Land MVP** |
| 5 | `google_calendar_event_observed` event_kind (omnibus per Google event) | §1.4 emit shape | S | Critical | **Land MVP** |
| 6 | `eventType=focusTime` signal (auto-decline mode + chatStatus) | §1.7 — per-event field, no extra HTTP | S | **Critical** | **Land MVP** — biggest delta vs EventKit |
| 7 | `eventType=outOfOffice` signal (auto-decline mode) | §1.7 — per-event field | S | Strong | **Land MVP** |
| 8 | `eventType=workingLocation` signal (home/office/custom bucket) | §1.7 — per-event field | S | Strong | **Land MVP** — cross-team co-location derived metric |
| 9 | `self.responseStatus` bucket (needsAction/accepted/declined/tentative) | §1.4 — attendees walk for self-row | S | Critical | **Land MVP** |
| 10 | `organizer.self` boolean | §1.4 — single field | S | Critical | **Land MVP** |
| 11 | `attendees.length` count + `external_attendee_count` bucket | §1.4 — walk array, domain compare to user's primary | S | Critical | **Land MVP** |
| 12 | `conferenceData.entryPoints[].entryPointType` bucket (video/phone/sip) | §1.4 — bucket only | S | Strong | **Land MVP** — meet/zoom detection that EventKit can't do |
| 13 | `conferenceData.conferenceSolution.key.type` (hangoutsMeet/addOn) | §1.4 — string bucket | S | Strong | **Land MVP** |
| 14 | `recurrence_frequency_bucket` (one_off/daily/weekly/monthly/yearly) | §1.4 — parse RRULE FREQ= | S | Strong | **Land MVP** |
| 15 | `transparency` (busy/available) + `visibility` bucket | §1.4 — enum fields | S | Strong | **Land MVP** |
| 16 | `status=cancelled` graceful handling (limited fields) | §1.4, §3.6 | S | Critical | **Land MVP** — failure-by-default if not handled |
| 17 | 410 Gone full-resync recovery per-calendar | §3.4 — wipe one calendar's token | M | Critical | **Land MVP** |
| 18 | `eventType=fromGmail` blocklist | §3.7 — skip filter | S | Critical | **Land MVP** — privacy posture |
| 19 | `eventType=birthday` blocklist | §3.7 — skip filter | S | Critical | **Land MVP** — contact PII |
| 20 | Multi-calendar fan-out (all subscribed) | §1.5 + §6.8 isolation | M | Strong | **Land MVP** (OQ-2 product call) |
| 21 | Token refresh on 401 + `reconnectNeeded` UI state | reuse Linear pattern | M | Critical | **Land MVP** |
| 22 | `RelayBodyLeakageTests` extensions (5 sentinels × N kinds) | §6.4 sentinel discipline | M | Critical | **Land MVP** |
| 23 | `DispatchCoverageTests` parity fence for new kinds | §6.2 dispatcher discipline | S | Critical | **Land MVP** |
| 24 | Cross-source dedupe via `iCalUID` ↔ `calendarItemExternalIdentifier` | derived insights layer | M | Strong | **Defer to Phase 4.9** (not P4) |
| 25 | `events.watch` push notifications | §1.3 — relay extension | M | Marginal | **Defer to v1.1** — 5-min poll covers MVP |
| 26 | OAuth incremental authorization (add scopes later) | §2.6 | S | Marginal | **Defer to v1.1** |
| 27 | `colorId` capture as anonymous category dimension | §1.4 — single field | S | Marginal | **Skip MVP** — value-unclear without UI surface |
| 28 | `attachments[].mimeType` bucket | §1.4 — array walk | S | Marginal | **Skip MVP** — value-unclear |
| 29 | `extendedProperties.private/.shared` | §1.4 | n/a | n/a | **Forbidden per ADR-010** |
| 30 | `gadget` (deprecated body content) | §1.4 | n/a | n/a | **Forbidden** |
| 31 | `source.url` / `source.title` (user-authored) | §1.4 | n/a | n/a | **Forbidden** |
| 32 | EventKit dedupe at write time (option β reconciliation) | new gating logic | L | Marginal | **Skip MVP** — use γ Hybrid (see OQ-3) |

**MVP scope:** items 1-23 (23 work units, mostly S effort).
**Deferred to v1.1:** items 24-26 (3 items).
**Skipped:** items 27-32 (forbidden or low value).

**Estimated event_kinds count:** 8-12 (omnibus `google_calendar_event_observed` + per-`eventType` discriminators + signals for `_created` / `_deleted` / `_cancelled` / `_rsvp_changed` / `_focus_block_started` / `_focus_block_ended` / `_ooo_started` / `_ooo_ended` / `_working_location_changed`). Contract §6.2 estimated ~6 — research suggests we'll land higher (8-12) once per-`eventType` discriminators are factored. Final count locked in brainstorm.

**ShareEventTypeKey delta:** baseline 152 → P4 target ~162 (+10 default-OFF entries). Within contract §6.2 ballpark.

---

## Section 8 — Open product questions for Stage 0 user gate

These must be answered before Stage 2 brainstorm begins. Recommendations stated; user gates the calls.

**Resolved 2026-05-16 (Alex):**
- **OQ-1** → `calendar.readonly` (single broad scope).
- **OQ-2** → All subscribed calendars (accessRole ∈ {owner, writer, reader}).
- **OQ-3** → γ Hybrid (independent collectors, dedupe in Derived Insights via iCalUID join, Phase 4.9).
- **OQ-A** (M027 shape) → not asked, locking recommendation: reuse `provider_snapshots` M015 (no new table for cursor).
- **OQ-4** (`events.watch` push) → not asked, locking recommendation: defer to v1.1.
- **GCP project** → create new `leaf-prod` from scratch (no existing project). Brand verification + sensitive scope verification path required. 100-user cap pre-approval acceptable for alpha distribution.

Phase 2 (brainstorm) starts from these locked positions.


### OQ-A — M027 shape: new table or reuse `provider_snapshots`?

`nextSyncToken` is an opaque string per calendar. `collector_offsets.last_modified_ms` is INTEGER and cannot store it. Two paths:

| Option | Behavior |
|---|---|
| **A. Reuse `provider_snapshots` M015** | rows: `(provider="google_calendar", snapshot_kind="sync_token:<calendar_id>", snapshot_json="{...token, last_full_sync_at_ms, bootstrap_in_progress}")`. Zero new schema. |
| **B. New `google_calendar_cursors` table (M027)** | dedicated table: `(workspace_id, calendar_id, sync_token, last_full_sync_at_ms, bootstrap_in_progress, access_role, discovered_at_ms, PRIMARY KEY(workspace_id, calendar_id))`. Cleaner queries; more code. |

**My recommendation: A (reuse).** Migration cost-free, follows Linear warm/cold tier precedent. Per-calendar `access_role` can live in `snapshot_json` payload. Move to B only if access_role-based queries become hot in derived insights.

### OQ-1 — Scope: `calendar.readonly` vs `calendar.events.readonly` + `calendar.calendarlist.readonly` (two-scope) vs `calendar.events.owned.readonly` (narrowest)

| Option | Pros | Cons |
|---|---|---|
| **A. `calendar.readonly` (single broad scope)** | One scope to verify. Covers CalendarList + events on all subscribed calendars (including team / public holiday / shared). Richest data. | Broadest. Reads ALL accessible calendars. Sensitive-scope verification (same as the other options anyway). Consent screen reads "See and download any calendar you can access" — high cognitive load. |
| **B. `calendar.events.readonly` + `calendar.calendarlist.readonly` (two scopes)** | Slightly less alarming on consent screen ("View events on all your calendars" + "See the list of Google calendars you're subscribed to"). | Two verification entries instead of one. Same data access as Option A. Marginal UX win. |
| **C. `calendar.events.owned.readonly` (narrowest)** | Consent reads "See the events on Google calendars you own" — minimal-feeling. | **Cannot see shared team calendars** — only calendars where user is `accessRole=owner`. For a team-presence product, this is a feature loss: shared "Engineering" calendar invisible. Cannot enumerate calendars (`calendarList.list` not in this scope's authorization list). |

**My recommendation: Option A (`calendar.readonly`).** Two reasons: (1) we want subscribed shared team calendars for Leaf's value (the only product reason Calendar matters); (2) verification path is identical across A/B/C, so narrowing buys consent-screen UX only and we lose product data.

**Open to push-back:** if onboarding-conversion is the primary worry, Option C is the privacy-safe default with an "Enable shared calendars" upgrade later via incremental authorization.

### OQ-2 — Calendar scope: primary only, all owned, or all subscribed (including shared)?

This is the *runtime* version of OQ-1. Even with `calendar.readonly` granted, we can choose at poll-time which calendars to walk.

| Option | Behavior |
|---|---|
| **i. Primary only** | `events.list?calendarId=primary`. One call per poll tick. Misses shared "Engineering" / "Customer interviews" calendars. |
| **ii. All owned (primary + secondary owned)** | Filter `calendarList.list` to `accessRole=owner`. Typical user: 1-3 calendars. Misses team-shared. |
| **iii. All subscribed (everything visible in user's UI)** | Filter `calendarList.list` to `accessRole in {owner, writer, reader}`. Skip `freeBusyReader`. Typical user: 5-20 calendars. Maximal signal. |

**My recommendation: (iii) all subscribed**, with per-calendar opt-out via Share Controls (default ON for owned, prompt-on-encounter for shared). Shared team calendars are where the cross-team-presence signal lives.

### OQ-3 — Reconciliation with EventKit: overlay or replace?

EventKit on macOS already exposes Calendar events (via the existing Calendar collector in Track 4 S1). Google's API gives us **richer** versions of those same rows for events synced from Google Calendar:
- `attendees[].self.responseStatus` (EventKit only exposes my own attendance via `EKEvent.status` which conflates with event state)
- `eventType=focusTime/outOfOffice/workingLocation` (EventKit doesn't surface)
- `recurrence[]` RRULE strings (EventKit gives `EKRecurrenceRule` objects — same data, different shape)
- `conferenceData.entryPoints[].entryPointType` (EventKit only gives the meeting URL, not the typed bucket)
- `transparency` (EventKit: yes, as `EKEventAvailability`)

**Three options:**

| Option | Behavior |
|---|---|
| **α. Overlay** | EventKit collector continues emitting `meeting_state_entered/exited` rows from system layer. Google Calendar collector emits new event_kind `google_calendar_event_observed` rows with the enriched payload. Two rows per "the same meeting" in DB. Derived insights join by `iCalUID` (Google) ↔ `EKEvent.calendarItemExternalIdentifier` (EventKit — typically maps to iCalUID for Google-synced calendars). |
| **β. Replace** | When Google account is connected, suppress EventKit calendar emissions for Google-sourced calendars (detected via `EKSource.sourceType == .calDAV` + identifier match). EventKit collector still handles iCloud / Exchange / local calendars. |
| **γ. Hybrid** | Keep both collectors fully independent. Compute de-dupe at Derived Insights query time, not at write time. Pay the storage cost for richness + audit trail. |

**My recommendation: γ. Hybrid.** Two reasons: (1) EventKit gives us the *real-time* "meeting started/ended" signal via the system layer (instant); Google poll gives us the *enriched metadata*. They're complementary, not competing. (2) Forever-history retention is cheap; reasoning about de-dupe at query time is cleaner than gating writes on cross-collector state.

The Derived Insights layer joins via `(iCalUID, start_ms)` tuple — handles most cases. Edge cases (iCloud-synced Google calendars exposing different iCalUIDs) acceptable as known noise.

### OQ-4 (bonus) — `events.watch` push: ship in P4 or defer to v1.1?

**My recommendation: defer.** Per §1.3 analysis — 5-min poll gets us 99% of the value, push requires `leaf-relay` Worker extension + Search Console domain verification + channel renewal job (Effort estimate: M). No real-time use case in MVP. Track as v1.1 candidate.

---

## Appendix A — Quick-reference URLs

| Topic | URL |
|---|---|
| events.list reference | `developers.google.com/workspace/calendar/api/v3/reference/events/list` |
| Event resource | `developers.google.com/workspace/calendar/api/v3/reference/events` |
| calendarList.list | `developers.google.com/workspace/calendar/api/v3/reference/calendarList/list` |
| events.watch (push) | `developers.google.com/workspace/calendar/api/v3/reference/events/watch` |
| Incremental sync guide | `developers.google.com/workspace/calendar/api/guides/sync` |
| Errors reference | `developers.google.com/workspace/calendar/api/guides/errors` |
| Quota guide | `developers.google.com/workspace/calendar/api/guides/quota` |
| Pagination guide | `developers.google.com/workspace/calendar/api/guides/pagination` |
| Recurring events guide | `developers.google.com/workspace/calendar/api/guides/recurringevents` |
| Calendar status / focus / OOO / working location | `developers.google.com/workspace/calendar/api/guides/calendar-status` |
| Auth + scopes | `developers.google.com/workspace/calendar/api/auth` |
| Native app OAuth | `developers.google.com/identity/protocols/oauth2/native-app` |
| Web-server OAuth (for refresh-token semantics) | `developers.google.com/identity/protocols/oauth2/web-server` |
| All OAuth 2.0 scopes (Calendar section) | `developers.google.com/identity/protocols/oauth2/scopes` |
| Verification policy | `support.google.com/cloud/answer/9110914` |
| Brand verification | `developers.google.com/identity/protocols/oauth2/production-readiness/brand-verification` |
| Push notifications general | `developers.google.com/workspace/calendar/api/guides/push` |

## Appendix B — Verification methodology

Every claim in this doc maps to either:
- A `mcp__plugin_context7_context7__query-docs` result against `/websites/developers_google_workspace_calendar_api` (Context7 mirror of `developers.google.com/workspace/calendar`) — these read "verified 2026-05 via context7" inline.
- A `WebFetch` call against the listed `developers.google.com` URL — these read "verified via WebFetch <URL>" inline.

Context7 mirror coverage: 851 documentation snippets indexed for `/websites/developers_google_workspace_calendar_api` as of 2026-05-16; benchmark score 80.22 / High source reputation. WebFetch used to fill identity/protocol gaps not in the Calendar-specific mirror.

No training-data-only claims. Every statement traces to a 2024+ Google source.
