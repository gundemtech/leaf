# Track 6 P3 — Browsers Deep · Stage 0 Research

**Stage:** Stage 0 (Deep Research) — companion to upcoming phase spec
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`
**Date:** 2026-05-16
**Author:** Dmitrii + Claude (research subagents: Explore on substrate; general-purpose on OSS recon)

This doc is the **input to brainstorm (Stage 2)**, not a plan. It maps the realistic ceiling of Safari + Chrome capture on macOS 15/16, surfaces the deltas between substrate and ceiling, flags one contract-level **assumption that does not hold against current evidence**, and surfaces 5 product questions for the user before brainstorm starts.

---

## 1. Current substrate (where we stand)

Sources: `Packages/LeafCore/Sources/LeafCore/OS/{SafariObservation,SafariStateMachine,ChromeObservation,ChromeStateMachine,ArcObservation,ArcStateMachine,BrowserTab,AppleScriptBridge,AppleScriptAdapter,AppleScriptAdapterRegistry,AppleScriptPermissionStore}.swift`; `Packages/LeafCorePrivate/Prod/Collectors/Apple/{ProdSafariAdapter,ProdChromeAdapter,ProdArcAdapter,ProdAppleScriptAdapterRegistry}.swift`; `Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift`; `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift`; `Packages/LeafCore/Sources/LeafCore/Collectors/{FSEventsCollector,FSEventsRouting,FSEventsIgnoreRules,WatchedFolder}.swift` + `Packages/LeafCore/Sources/LeafCore/Internal/FSEventStream.swift`.

| Dimension | Current state |
|---|---|
| **Capture mechanism** | `NSAppleScript` per-tick poll via `AppleScriptBridge` (`@MainActor` wrapper). One adapter per browser. Bundle IDs `com.apple.Safari`, `com.google.Chrome`, `company.thebrowser.Browser`. 30 s tick. 1.0 s timeout. |
| **event_kinds emitted** | **3 total:** `safari_tabs_changed`, `chrome_tabs_changed`, `arc_tabs_changed`. All emit only when **URL-set membership** of front-window tabs differs from previous tick (order-agnostic, no per-tab nav signal). |
| **Payload fields per emit** | `event_kind`, `active_window_id` (optional), `tabs` = JSON-encoded `[{title, url}]`. Only `title` + `url` cross the boundary. **Source / text / history / cookies / localStorage** explicitly forbidden by per-adapter source-grep test (`BrowserTab.swift:5–7` comment). |
| **TCC posture** | Automation entitlement (`NSAppleEventsUsageDescription` in `LeafAgent.app`). First tick after Local Apps toggle ON triggers OS Automation dialog per bundle ID. Code `-1743 → .denied`. No Full Disk Access required. |
| **ShareEventTypeKey** | `.safariTabsChanged`, `.chromeTabsChanged`, `.arcTabsChanged` — all default OFF (`ShareEventTypeRegistry.swift:194–196`, defaults at `:436–438`). |
| **ActivityFeedMapper** | `mapLocalOS` (`ActivityFeedMapper.swift:628,630,632`): `"Safari: N tabs"` / `"Chrome: N tabs"` / `"Arc: N tabs"`. Pure cardinality — no URL or title in primaryText. |
| **State machine emission semantics** | `SafariStateMachine.observe()` / `ChromeStateMachine.observe()` — emit only when `Set<url> != prevSet`. **Tab order changes alone do NOT emit. Within-tab URL navigation (same tab, different page) does NOT emit if the URL ends up in the set anyway.** Per-tab attribution is not retained. |
| **Tests** | `SafariStateMachineTests` (5), `ChromeStateMachineTests` (4), `ArcStateMachineTests`, `ActivityFeedMapperLocalOSTests` browser block (l. 196–234), `RelayBodyLeakageTests` browser sentinel (l. 1619–1640), `AppleScriptCollectorDispatchTests`. |
| **Substrate count** | Registry 152 entries (baseline per `current-state.md`). 3 already in for browsers (S2). |

**Net:** P3 inherits a working AppleScript surface that delivers tab-set diff at 30 s cadence. The 152 → ~190 ambition in the contract is unmet — within-tab nav, bookmarks, downloads, history visits, reading list, per-domain capture are all green-field.

---

## 2. Vendor ceiling per mechanism (2026-05)

### 2.1 Safari AppleScript dictionary (macOS 15 / 16, Safari 18)

**No changes** between macOS 14 → 15 → 16 (macscripter — "Scripting Changes in macOS Tahoe", 2025-Q3). What is scriptable:

- `application Safari` — `windows`, `documents`, `current tab`.
- `window` — `tabs` (list), `current tab` (front tab in that window), `index`.
- `tab` properties: **`URL`** (string), **`name`** (page title), **`source`** (full HTML — privacy hazard), **`text`** (rendered DOM text — privacy hazard), `index`, `visible`.
- Commands: `do JavaScript in <tab>` (privacy hazard).

**Private windows AS-invisible** — Safari excludes Private windows from the dictionary by design. No filter needed in adapter.

**Reading list** — exposed via Bookmarks.plist (see §2.5), not via Safari's AS dictionary.

**Bookmarks** — Safari's dictionary does **not** expose bookmarks as scriptable entities. File-watch is the only path. Bookmarks.plist lives in `~/Library/Safari/Bookmarks.plist` → FDA-protected (see §3.1).

**Downloads** — not exposed via Safari AS. Persisted into `~/Library/Safari/Downloads.plist` → FDA-protected.

### 2.2 Chrome AppleScript dictionary (Chromium design doc)

- `application` — `windows`.
- `window` — `tabs`, `active tab index`, `active tab`, **`mode`** (`normal` | `incognito`).
- `tab` properties: **`URL`**, **`title`** (note: Chrome uses `title`; Safari uses `name`), `loading` (bool), `id`, `executing javascript`.
- Commands: `reload`, `go back`, `go forward`, `execute javascript`, `view source` (all privacy hazards Leaf already excludes).

**Incognito** — `window.mode` returns `incognito`; we already rely on AS-invisibility convention but can explicitly filter on `mode != normal`.

**`tab.id`** is stable per session — gives us a real handle for per-tab nav diffing. Safari has only `index` + `name + URL` for stable identity (index reorders).

**Bookmarks** — not via Chrome AS. Persisted to `~/Library/Application Support/Google/Chrome/Default/Bookmarks` — **JSON file, NOT FDA-protected** (lives outside `~/Library/Safari/` and outside `~/Library/Containers/`). Safe to FSEvents-watch.

**Downloads** — Chrome persists to `~/Library/Application Support/Google/Chrome/Default/History`'s `downloads` table — same DB as History, same locking pain (see §2.3).

### 2.3 Safari `History.db` + Chrome `History`

**Safari** — `~/Library/Safari/History.db` (SQLite). Schema: `history_items` (id, url, visit_count, ...), `history_visits` (id, history_item FK, **visit_time REAL** — CFAbsoluteTime / seconds since 2001-01-01, **title**, redirect_source, generation). WAL companion `History.db-wal` mutates constantly while Safari runs.

**Chrome** — `~/Library/Application Support/Google/Chrome/Default/History` (no extension). Schema: `urls` (id, url, title, visit_count, last_visit_time), `visits` (id, url FK, **visit_time** — Chrome epoch / microseconds since 1601-01-01 UTC, transition, **visit_duration**), `downloads`. WAL companion `History-wal`.

**Locking is hostile in both cases:**

- Safari typically returns `SQLITE_BUSY` to third-party readers while running. Workaround `?mode=ro&nolock=1` or `SQLITE_OPEN_IMMUTABLE` — possible but reader sees a stale or torn view; SQLite docs warn explicitly. Forensic tools (Velociraptor, Belkasoft) prefer offline disk-image snapshots.
- Chrome holds an **exclusive write lock** while running. Reliable read requires either (a) `cp` snapshot then open the copy, (b) `nolock=1` URI accepting staleness/risk, or (c) full process kill. Snapshot-copy is the only widely-used "correct" path — Datasette and forensic tools both go this route.

**Incognito private windows do NOT write to either History DB.** So even with a working reader we don't get back the AS-invisibility behaviour for free — and we don't gain it either.

**`~/Library/Safari/*` is gated by Full Disk Access TCC** (alongside Mail, Messages, Calendar's stronger store paths). Reading `History.db` requires the user to grant Leaf FDA, which is a separate Privacy → Full Disk Access pane toggle — large drop-off. ActivityWatch explicitly chose the WebExtension route to avoid this; RescueTime chose AppleScript for the same reason.

**`~/Library/Application Support/Google/Chrome/Default/*` is NOT FDA-protected** — it lives outside the FDA umbrella (verified by community + matched by lack of TCC prompts from forensic tooling). So Chrome's history is FDA-free but still locking-hostile.

### 2.4 Reading list / Bookmarks file format

**Safari Bookmarks.plist** (`~/Library/Safari/Bookmarks.plist`) — binary plist, top-level dict with `Children` array. Reading list is a child dict with `Title = "com.apple.ReadingList"`. **FDA-protected — same gate as History.db.**

**Chrome Bookmarks** (`~/Library/Application Support/Google/Chrome/Default/Bookmarks`) — JSON file with `roots.bookmark_bar.children[]`. Plain readable, no FDA. Modified atomically by Chrome (write to `Bookmarks.tmp` then rename — clean FSEvents signal).

### 2.5 AX `AXWebArea` / `AXURL` (window-title fallback)

Existing in Leaf substrate via `AXObservation` (Track-4 S2-precedent for non-scriptable browsers — Brave, DuckDuckGo, Vivaldi, Orion). Reads window title only. **URL via `AXWebArea → AXURL`** is theoretically richer but reliability varies per-browser per-version. Out of scope for P3 — keep AX fallback as-is, do not extend.

### 2.6 Non-Chromium non-Safari browsers

| Browser | AS surface | Path |
|---|---|---|
| Brave | Minimal / inconsistent (community-confirmed open issue brave/browser-laptop#665). | AX fallback only. |
| Arc | Limited; community variance. **Already substrate-wired** (Track-4 S2 `arc_tabs_changed`). Bundle ID `company.thebrowser.Browser`. |
| DuckDuckGo for Mac | Confirmed **none** (Tsai blog 2022; macscripter threads). | AX fallback only. |
| Orion (Kagi) | Has AS (community-confirmed). | Out of scope. |
| Vivaldi | Limited, community asks for more (forum 37920). | Out of scope. |
| Firefox | None (consistent vendor stance). | Extension or AX fallback only. **Out of scope.** |

**P3 scope confirmation needed:** contract says "Safari + Chrome." Arc has substrate already and is the third tier-1 user-facing browser. Either include Arc in P3 deeper events (it's already wired) or leave Arc capped at S2 baseline. See product question Q5.

---

## 3. TCC / sandbox audit

| Mechanism | TCC prompt? | Drop-off risk | Reliability across users |
|---|---|---|---|
| AS `tell application "Safari" / "Google Chrome"` for per-tab nav (URL + title) | Automation prompt **already paid** by Track-4 S2 toggle | None — already onboarded if user enabled Safari/Chrome in Local Apps | Universal (Safari 18+, Chrome current) |
| AS for Safari Reading List | Not available via AS — needs file read | n/a | n/a |
| FSEvents on `~/Library/Application Support/Google/Chrome/Default/Bookmarks` | No new prompt — `~/Library/Application Support/<vendor>/` is not FDA-gated | None | Universal |
| Read Chrome `Bookmarks` JSON file | No new prompt | None | Universal |
| FSEvents on `~/Library/Safari/Bookmarks.plist` | **Yes — Full Disk Access** | **High** (separate pane in System Settings) | Drops to whichever users grant FDA |
| Read Safari `History.db` | **Yes — Full Disk Access** + locking pain | **High** + correctness risk | Drops sharply |
| Read Chrome `History` (sqlite) | No FDA prompt, **but** exclusive-lock conflict | Correctness risk under live use; need snapshot-copy or `nolock=1` | Universal IF we accept staleness |
| FSEvents on `~/Downloads` | No new prompt — Track-4 S3 already watches | None | Track-4 S3 ships `download_added` |

**Net:** Every Safari `~/Library/Safari/` mechanism costs FDA — Leaf's policy posture and ActivityWatch's empirical choice are aligned: avoid. Chrome's local files are mostly FDA-free but History sqlite is locking-hostile. AppleScript-only surface stays inside the TCC envelope we already paid.

---

## 4. OSS reconnaissance — what others do

Source: general-purpose subagent (full citations in subagent output; key links below).

| Project | Mechanism | Why | Note |
|---|---|---|---|
| **ActivityWatch `aw-watcher-web`** | WebExtension only | Real-time + incognito-respect; avoids FDA cliff | Cross-browser; users must install per browser. Issue #91: Brave support degraded. Issue #123: incognito leak bug — extension fails open occasionally. |
| **RescueTime macOS** | AppleScript per supported browser + Firefox extension fallback | User-facing UX — Automation pane is well-understood | Closed-source; no per-event payload schema published. |
| **Wakatime `browser-wakatime`** | WebExtension (TypeScript) | Cross-IDE company already in extension business | Heartbeat payload: `entity` (URL or domain), `type`, `time`, `category`, allowlist/denylist sites. |
| **arbtt / Tockler / Selfspy / ulogme** | Foreground window title scrape | Simplest; no per-browser code | Lossy URLs (Chrome doesn't put URL in title; Safari does — partially). No download/bookmark signal. |
| **Velociraptor / Belkasoft / foxtonforensics** | Snapshot-copy History DBs, parse offline | Forensic context, not live | Cross-platform Python; not a live-system pattern. |
| **Cluely** | Screen recording / OCR | Anti-pattern — Leaf explicitly excludes (Layer A won't-list) | — |
| **Arc** | Sentry + Segment + LaunchDarkly + bespoke storage | **Anti-pattern incident** CVE-2024-45489 (Sept 2024) — analytics SDK leaked app-state events to third-party telemetry. Lesson: never wire browser-derived strings through any third-party SDK. | — |

**Synthesis.** Local activity loggers **don't** live-read History.db. They either ship an extension or settle for AppleScript + title scrape. Forensic tools snapshot-copy. The substrate-natural path for Leaf is AppleScript depth — extension and live-sqlite paths both have steep costs that none of the live-system OSS projects accept.

Sources: aw-watcher-web (github.com/ActivityWatch/aw-watcher-web — README, issues #91 #123), RescueTime help (help.rescuetime.com articles 257/57/115/45), browser-wakatime (github.com/wakatime/browser-wakatime), Velociraptor Safari artifact (docs.velociraptor.app), Arc CVE-2024-45489 incident response (arc.net/blog), Chromium AppleScript design doc (chromium.org/developers/design-documents/applescript/), macscripter Tahoe changes (macscripter.net/t/77173).

---

## 5. Ceiling-vs-effort table

Per contract §3.1 — every viable signal, mechanism, effort, value tier. **Skip Marginal unless effort is S.**

### 5.1 Within-tab navigation (per-tab URL change)

| event_kind | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| `safari_tab_navigated` | AS per-tick: collect `(tab_index, name, URL)` per front-window tab; diff against per-tab map (`SafariNavStateMachine`). Emit when an existing tab changes URL (not membership). | S–M | **Critical** | Within-tab nav is the main signal users notice. Today completely missing. Allow-list-gated payload (Q3). |
| `chrome_tab_navigated` | AS per-tick: same with `tab.id` (stable across reorder — Chrome only). | S | **Critical** | Same. |
| `arc_tab_navigated` | AS per-tick (Arc only if Q5 says include). | S | Strong | Reuse infrastructure. |

### 5.2 Tab activation / focus within browser

| event_kind | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| `safari_tab_activated` | AS: per-tick read `current tab of front window`; diff vs previous tick. | S | Strong | Distinct from app focus (NSWorkspace already covers). Activation within Safari window. |
| `chrome_tab_activated` | AS: `active tab index` of front window. | S | Strong | Same. |
| `arc_tab_activated` | AS Arc only if Q5. | S | Strong | — |

### 5.3 Bookmarks

| event_kind | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| `chrome_bookmark_changed` | FSEvents on `~/Library/Application Support/Google/Chrome/Default/Bookmarks`; emit on mtime change with bookmark count diff (open + count children). No FDA. **Title NEVER captured.** | M | Strong | Surfaces "I just bookmarked something" signal. Per-folder counts only. |
| `safari_bookmark_changed` | FSEvents on `~/Library/Safari/Bookmarks.plist` — **FDA cliff**. | M | **Marginal** | High drop-off cost. Recommend SKIP unless Q4 changes posture. |

### 5.4 Downloads (per-browser)

| event_kind | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| `chrome_download_started` | Snapshot-copy + parse `downloads` table of Chrome History DB, or watch Chrome's per-download `.crdownload` temp files via FSEvents on `~/Downloads/`. | M–L | **Marginal** | Track-4 S3 already emits generic `download_added` from FSEvents on `~/Downloads/`. Per-browser attribution would need either DB read (locking pain) or `.crdownload` detection (Chrome-specific, fragile). Cost > value. Recommend SKIP — track-4 S3 generic event is sufficient. |
| `safari_download_started` | Same — FDA pain. | L | Marginal | SKIP. |

### 5.5 Reading list (Safari)

| event_kind | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| `safari_reading_list_changed` | FSEvents + plist parse of `~/Library/Safari/Bookmarks.plist` (reading list lives there). FDA cliff. | M | Marginal | SKIP — Safari-only, FDA-gated, low signal value. |

### 5.6 History visit (granular sqlite read)

| event_kind | Mechanism | Effort | Value | Notes |
|---|---|---|---|---|
| `safari_history_visited` | Snapshot-copy + sqlite read `History.db`. **FDA gate + locking + staleness.** | L | **Marginal** | SKIP. AppleScript per-tab nav covers the live signal; history adds only backfill + transitions. ActivityWatch/RescueTime both skipped this. |
| `chrome_history_visited` | Snapshot-copy + sqlite read `History`. Locking-hostile but no FDA. | L | Marginal | SKIP. Same reasoning. |

### 5.7 What we DON'T capture (Won't-list per contract §7)

- **Full URLs for non-allow-listed domains** — only domain bucket (or hash, per Q3). Allow-list-only domains see L4-L5 capture.
- **Tab titles for non-allow-listed domains** — same.
- **Source / text / `do JavaScript`** — permanently forbidden.
- **Bookmark titles** — never captured (only counts).
- **Cookies / form data / autofill** — permanently forbidden.
- **Per-tab page DOM, screenshots, scroll position** — forbidden.

`RelayBodyLeakageTests` extended per new event_kind. Sentinel-injection regression per payload tree.

---

## 6. Contract drift — assumption that does not hold

Contract §7 P3 reads:

> *Opt-in per-domain allow-list pattern (mirror Track-3 Slack channel allow-list). History sqlite watcher reads URLs only when allow-list matches.*

Two issues with the citation:

1. **No Slack channel allow-list exists in the codebase.** Grep for `channel.*allow`, `allow_list`, `enabledChannel`, `whitelist` returns zero hits in `Packages/LeafCore/Sources/LeafCore/Collectors/Slack*.swift`, `Packages/LeafCorePrivate/Prod/Collectors/ProdSlackAPIProvider.swift`, the D3 spec/plan, and the migrations. Slack's current capture is `ShareEventTypeKey`-gated at event_kind level only, not at per-channel level. So "mirror Slack channel allow-list" is forward-looking — no precedent to copy.
2. **History sqlite watcher** as a primary mechanism contradicts the OSS evidence (§4) and the TCC/locking evidence (§2.3 + §3). Live-reading Safari History.db pays FDA. Live-reading Chrome's History pays a snapshot-copy or accepts torn reads. Neither delivers signal that AppleScript per-tab nav doesn't already give us at lower cost.

**Implication for the contract**: M026 reservation was framed as "Browser history watch substrate + per-domain allow-list table + watcher cursor table." Two of three components need re-scoping:

- **Per-domain allow-list table** is needed — but as a **new substrate** (not a mirror of a non-existent Slack pattern). See product question Q2.
- **Watcher cursor table** is irrelevant if there is no sqlite watcher.
- **History watch substrate** — recommend SKIP per §5.6.

M026 collapses to a single thin migration: per-domain allow-list table + (optional) per-tab cursor for the nav state machine.

---

## 7. Schema deltas

Recommended **post-research, pre-brainstorm** (final shape settled in Stage 2):

- **M026 — Browser per-domain allow-list table.** Single thin migration. Columns: `domain TEXT PRIMARY KEY`, `granularity TEXT NOT NULL CHECK(granularity IN ('full_url','path_stripped','domain_only')) DEFAULT 'full_url'`, `added_at_ms INTEGER NOT NULL`, `notes TEXT`. Default empty (matches default OFF).
- **No additional tables** if §5.3–§5.6 SKIP recommendations stand. Per-tab state machines hold prev-tick maps in-memory only (lost on restart, like S2 `prevURLSet`).
- **ShareEventTypeKey deltas:**
  - Per-tab nav (§5.1): `safari_tab_navigated`, `chrome_tab_navigated`, (+ `arc_tab_navigated` if Q5) = 2 or 3 entries
  - Per-tab activation (§5.2): `safari_tab_activated`, `chrome_tab_activated`, (+ `arc_tab_activated` if Q5) = 2 or 3 entries
  - Bookmarks (§5.3): `chrome_bookmark_changed` = 1 entry (Safari dropped per §3 FDA cliff)
  - All default OFF.
  - **Total P3 = 5–7 entries.** Contract §6.2 estimate was ~8 — within envelope.
- **Registry baseline 152 → P3 target ≈157–159.** Track-6 cumulative running: P1 168, P3 158-ish → 162-168 floor for whole-track ≈190 target after P2 + P4 + P5 + P6.

---

## 8. Anti-patterns from prior tracks

Carry-overs from `current-state.md` "Open tensions" + Track-3/4 reviews. Applicable here:

1. **Cold-start race** (Track 3 D3 Slack, Track 4 S4). Per-tab nav state machine cold tick #1 emits before prev-tab map established → false nav events for every initial tab. **Mitigation:** first observation seeds prev-state without emitting; same pattern as `SafariStateMachine.observe` (`prevURLSet == nil → seed only`).
2. **Dispatcher parity drift** (Track 4 S4 MAJOR-1 review reject). Payload keys in collector ≠ keys in `ActivityFeedMapper.mapLocalOS` → blank Activity row. **Mitigation:** canonical key names defined once; `DispatchCoverageTests` parity fence per new event_kind. Per-tab nav payload likely needs `previous_url` + `current_url` + `tab_index` (or `tab_id` Chrome only) — all need to flow through allow-list filter consistently in both collector emit and mapper read.
3. **Sentinel-leak regression** (Track 4 S3). New payload trees must walk for forbidden fields. **Mitigation:** `RelayBodyLeakageTests` per new event_kind. Sentinel injection on `previous_url`, `current_url`, `tab_title`, `domain` keys.
4. **Raw third-party IDs in payload** (Track 4.7.C). Chrome `tab.id` is per-session ephemeral — capturing it is fine (not third-party identity). Window ID same. No anonymization needed.
5. **Body-kind dispatcher tuple refactor** (Track 4 S4). If P3 carries user-authored strings in payload (tab title in allow-listed flows), the dispatcher needs the tuple signature. Tab title is user-authored (page chose it) → IS body, treat as `Schema.BodyKinds.browserTabTitle` for FTS dispatch. Confirm in brainstorm.
6. **`prevURLSet`-on-restart loss** (S2 pattern). Per-tab nav map is in-memory → after Agent restart, first tick re-seeds without emit (correct behaviour, matches S2). Document explicitly.
7. **Per-app share-key check vs per-domain allow-list** (new for P3). Two orthogonal gates: ShareEventTypeKey gate (the event_kind itself is enabled) and per-domain allow-list (this specific domain is opted in for L4-L5). Both must be checked **before** payload write. Order: share-key first (early-exit), then allow-list (controls granularity). Cold-start race here too — allow-list reader called before allow-list table seeded → returns empty → all events fall to domain-only. That's the correct cold behaviour.
8. **Locale variants in AS dictionary.** Both Safari and Chrome AS dictionaries use English literals (`tabs`, `URL`, `name`, `title`) regardless of UI locale. Verified by macscripter Tahoe note. No locale risk for P3.

---

## 9. Decisions (locked-in 2026-05-16, brainstorm anchor)

User directive carrying over from P1: *"сделать охуенно с первого раза без больших доработок после."* Decisions optimize substrate-correctness up front.

### D1 — Mechanism: AppleScript-only, no History sqlite watcher

**Decision:** AS-deep is the substrate. History.db/sqlite watching is SKIPPED.

- **Why:** every OSS local logger surveyed either uses extension or AS; none live-reads History.db. FDA cliff on Safari is unjustified. Chrome's sqlite locking is hostile. AS gives live URL+title at lower cost.
- **What we lose:** historical backfill (already gone — fresh installs see nothing pre-install regardless), transition type (typed/link/autocomplete — Chrome only signal). Cost of recovering: high. Value: marginal in user-facing recall (we capture the visit live; transition is post-hoc curiosity).
- **What we gain:** zero new TCC prompts. Cleaner privacy story. Lower test surface. No snapshot-copy cost.

### D2 — M026 collapses to allow-list table only

**Decision:** M026 ships **one** table — `browser_domain_allow` — not three.

- Schema: `domain TEXT PRIMARY KEY, granularity TEXT NOT NULL CHECK(granularity IN ('full_url','path_stripped','domain_only')) DEFAULT 'full_url', added_at_ms INTEGER NOT NULL, notes TEXT`.
- Default empty. Default behaviour = whatever Q3 says for non-allow-listed domains.
- Drop "watcher cursor table" (no watcher).
- Drop "browser history substrate" (no sqlite read).

### D3 — Default URL granularity for non-allow-listed domains

**Decision proposal (subject to Q3):** **`domain_only`** for non-allow-listed domains.

- `full_url` → domain-only-strip path/query for non-allow-listed.
- Page title → drop entirely for non-allow-listed.
- Allow-list adds the domain back to `full_url` granularity.
- Tab count signal (`safari_tabs_changed` cardinality) remains domain-anonymised payload (already domain-only via existing JSON encoding — wait, no: existing emits full URLs in `tabs` payload field! See §10 Open mini-question on backward-compat).

### D4 — Within-tab nav is THE main event_kind P3 adds

**Decision:** `safari_tab_navigated` + `chrome_tab_navigated` are the headline events. Per-tab activation is secondary signal. Bookmarks/downloads stay marginal.

- Why: the existing `*_tabs_changed` URL-set membership signal misses ~90% of real navigation (most nav is open-tab-replace-URL, not new-tab-different-URL). Per-tab nav is the substrate-fixing P3 owes us.
- Mechanism: enrich AS script to read per-tab `(index/id, URL, name)`; per-tab state machine diffs URL by tab handle.

### D5 — Reuse existing `*_tabs_changed` substrate; don't break it

**Decision:** `safari_tabs_changed` / `chrome_tabs_changed` / `arc_tabs_changed` stay as-is. P3 layers per-tab nav alongside, not replacing.

- Same adapter, enriched tickScript, separate state machine (`SafariNavStateMachine` / `ChromeNavStateMachine`) feeding new event_kinds.
- Old set-diff state machine continues for cardinality signal.
- Two emissions possible per tick if both URL-set membership AND per-tab URL changed.

### D6 — Catch-all discipline (Track 4 S4 lessons)

- **Dispatcher tuple** — confirm in brainstorm if `tab_title` goes through `Schema.BodyKinds` (likely yes as `.browserTabTitle`).
- **DispatchCoverageTests parity fence** extended per new event_kind.
- **Sentinel-injection RelayBodyLeakageTests** per new event_kind (per-domain allow-list bypass test + `previous_url`/`current_url`/`title` walkback).
- **Cold-vs-warm tick branch** test per new state machine.
- **Per-event-kind cadence health** flagged as known carry-over to Phase 4.9.

---

## 9a. Brainstorm-stage mini-questions (technical, not product)

Don't block Stage 0 → Stage 1, but resolve before plan-write:

- Exact payload key naming for per-tab nav — `previous_url` / `current_url` / `tab_index` / (`tab_id` Chrome) / `title`. Consistency across browsers vs idiomatic per-browser difference (`tab_id` exists only for Chrome).
- Backward-compat on existing `safari_tabs_changed` payload: today it embeds full URLs in `tabs` JSON. If D3 says "domain-only by default for non-allow-listed", do we filter the existing `tabs_changed` payload too, or only new event_kinds? Recommend: **also filter** the existing payload — same rule, no exceptions.
- Bookmark count delta — does P3 ship `chrome_bookmark_changed` despite the lower value tier, given it's "free" (FSEvents already wired)? Recommend: defer to brainstorm.
- Per-tab activation event_kind cadence — at 30 s tick, activation is lossy (user can switch tabs 10x per minute). Either tighten cadence to 10 s for activation-only signal, or accept lossy. Recommend: keep 30 s tick, accept lossy (matches existing posture).
- Allow-list reader cache: read every tick from DB or cache in actor? Per-tick is fine at 30 s × N browsers.
- Allow-list UI surface — Settings → Privacy → Browser Allow-list standalone screen, or sub-section of Settings → Local Apps. **Brainstorm**.
- `arc_tabs_changed` extension to `arc_tab_navigated` — same mechanism, but Arc's AS reliability is variance-prone. Either include with graceful degrade, or skip Arc per-tab nav (keep S2 cardinality). Tied to Q5.

---

## 10. Estimated registry delta (post-decisions)

Per Track-6 contract §6.2, refined by §9 decisions.

| Event kind | Source | Default |
|---|---|---|
| `safari_tab_navigated` | D4 | OFF |
| `chrome_tab_navigated` | D4 | OFF |
| `safari_tab_activated` | §5.2 | OFF |
| `chrome_tab_activated` | §5.2 | OFF |
| `chrome_bookmark_changed` (if accepted) | §5.3 | OFF |
| (`arc_tab_navigated` / `arc_tab_activated` if Q5 says yes) | D4 / §5.2 | OFF |

**Registry baseline 152 → P3 target ≈157–159** (5–7 net-new).

Contract §6.2 estimate was ~8; refined to 5–7 with sqlite/history/downloads/reading-list/Safari-bookmarks dropped.

---

## 11. Surfaced product questions

To answer **before** Stage 1 Discovery (per contract §3.1 item 7). All five are short.

### Q1 — Mechanism scope: AS-only vs include history sqlite watcher

**Recommendation: AS-only (drop history sqlite watcher).**

- Pro: zero new TCC prompts, no FDA cliff, no snapshot-copy correctness risk, cleaner privacy story, lower test surface.
- Con: no backfill on first install; no transition-type signal (typed/link/autocomplete — Chrome only); no per-visit duration (chrome `visit_duration` is post-hoc anyway).
- Evidence: ActivityWatch + RescueTime + Wakatime all skip live sqlite reads. Forensic tools snapshot-copy offline only.

### Q2 — Per-domain allow-list mechanism

The contract claims this mirrors a Track-3 D3 Slack channel allow-list. **No such allow-list exists in the codebase or in the D3 spec/plan.** So P3 builds the first one. Three options:

- (a) **Dedicated `browser_domain_allow` table** (M026). P3-local, simple. Recommended.
- (b) Pull forward `share_event_types` runtime UPSERT from Phase 5.4 and treat per-domain as rows in that table or as a sub-key. Higher impact, blocked-by Phase 5.4 readiness.
- (c) UserDefaults-only until Phase 5.4 ships. Lossy across reinstall; harder to test.

**Recommendation: (a).** Stays inside P3 scope. Phase 5.4 can later absorb if needed.

### Q3 — Default URL granularity for non-allow-listed domains

Three options:
- (a) **`domain_only`** — strip path/query. Preserves "you visited github.com today." **Recommended.**
- (b) **Hash full URL** — uniqueness preserved, readability lost. Marginal value to user.
- (c) **Don't emit at all** — strict L1-L2 (Safari/Chrome app-active duration only).

**Recommendation: (a).** Matches Slack DM bucketing pattern (`"DM"` generic vs specific channel). User sees "visited 12 distinct domains in github.com territory" without seeing exact pages.

### Q4 — Safari Bookmarks.plist (FDA cliff)

`~/Library/Safari/Bookmarks.plist` is FDA-gated. Chrome's Bookmarks is not.

**Recommendation: skip `safari_bookmark_changed`.** Ship only `chrome_bookmark_changed` (or drop both, see Q4-bis).

Q4-bis: ship `chrome_bookmark_changed` (Chrome-only, FSEvents-cheap)? Pro: free signal; Con: asymmetric between Safari and Chrome. **Recommendation: ship.** Asymmetry is honest — Safari has FDA on bookmarks; we document that.

### Q5 — Arc inclusion in P3

Contract says "Safari + Chrome." Arc already has substrate (`arc_tabs_changed` from Track-4 S2). Within P3 we could:
- (a) **Skip** — Arc stays at S2 cardinality. Contract-faithful. **Recommended for first cut.**
- (b) Include Arc per-tab nav + activation, with the same fallback discipline if Arc's AS dictionary returns partial data.

**Recommendation: (a).** Arc's AS reliability variance argues against shipping per-tab nav in P3 timeline. Track-6 P-something-or-other can add it later if Arc fixes their dictionary.

---

## 12. References

- Phase contract: `docs/superpowers/specs/2026-05-15-track-6-existing-surface-depth-contract.md`
- P1 research precedent: `docs/superpowers/specs/2026-05-15-track-6-P1-claude-code-research.md`
- Architecture: `.claude/shared/architecture.md` (Layer A — AS / FSEvents lines; Share Controls — ADR-020 block)
- Current-state: `.claude/shared/current-state.md` (Track-4 S2/S3/S4 carry-overs)
- ADR-010 / Won't-list: whitepaper `~/Desktop/Leaf/leaf-docs/docs/privacy-security/wont-list.md`
- Safari History.db schema: gist.github.com/l1x/68e206f56bcc22cde3d76cc8fed49f3f
- Chromium AppleScript design: chromium.org/developers/design-documents/applescript/
- Macscripter Tahoe AS changes (2025): macscripter.net/t/scripting-changes-or-lack-thereof-in-macos-tahoe/77173
- ActivityWatch aw-watcher-web: github.com/ActivityWatch/aw-watcher-web (README + issues #91 #123)
- Wakatime browser plugin: github.com/wakatime/browser-wakatime
- RescueTime macOS browser tracking: help.rescuetime.com/article/257-enabling-website-tracking-on-macos
- Arc CVE-2024-45489 incident: arc.net/blog/CVE-2024-45489-incident-response
- SQLite immutable flag forum: sqlite.org/forum/info/a2e9387b8ea1c919b2ad1ecafb417cebb15c48634c55b3abd6a9acbb2fabf797
- Chromium history DB locking bug: bugs.chromium.org/p/chromium/issues/detail?id=532555
- Datasette `--nolock` discussion: github.com/simonw/datasette/issues/1744

---
