# Track 6 P3 — Browsers Deep · Design Spec

**Stage:** Stage 3 (Spec) — input to plan + implementation
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`
**Research companion:** `2026-05-16-track-6-P3-browsers-research.md`
**Date:** 2026-05-16
**Author:** Alex + Claude

---

## 1. Goal & non-goals

### 1.1 Goal

Bring Safari + Chrome + Arc capture from Track-4 S2 baseline (front-window tab-set diff only) to depth-parity with Track-3 D1/D2/D3 providers — per-tab navigation events, per-tab activation, per-browser bookmark count delta — gated behind an **opt-in per-domain allow-list**. Default-OFF privacy posture preserved.

### 1.2 Eight new `event_kind` discriminators

| Event kind | Browser | Source mechanism | Default share-key |
|---|---|---|---|
| `safari_tab_navigated` | Safari | AppleScript per-tick, positional diff | OFF |
| `chrome_tab_navigated` | Chrome | AppleScript per-tick, `tab.id` diff | OFF |
| `arc_tab_navigated` | Arc | AppleScript per-tick, `tab.id` diff with graceful degrade | OFF |
| `safari_tab_activated` | Safari | AppleScript per-tick, `current tab of front window` diff | OFF |
| `chrome_tab_activated` | Chrome | AppleScript per-tick, `active tab index` diff | OFF |
| `arc_tab_activated` | Arc | AppleScript per-tick, with graceful degrade | OFF |
| `chrome_bookmark_changed` | Chrome | FSEvents on `~/Library/Application Support/Google/Chrome/**/Bookmarks` | OFF |
| `safari_bookmark_changed` | Safari | FSEvents on `~/Library/Safari/Bookmarks.plist` (FDA-gated) | OFF |

Registry baseline 152 → 160 after P3 (matches contract §6.2 ~8 estimate).

### 1.3 Behavioural defaults locked in Stage 0

- **AS-only mechanism.** No SQLite History watcher. (Q1)
- **Dedicated `browser_domain_allow` table** (M026). Allow-list is per-domain rows; default empty. (Q2)
- **`domain_only` default granularity** for non-allow-listed domains. (Q3)
- **Ship Chrome + Safari bookmarks + Arc per-tab nav.** Safari bookmarks accept the FDA TCC cliff. (Q4)

### 1.4 Non-goals

- **No History.db / Chrome `History` sqlite reading.** ADR-010 + OSS evidence + TCC cost.
- **No browser extension.** Distribution cost out of P3 scope.
- **No reading list (Safari-specific).** Out of scope.
- **No downloads.** Track-4 S3 `download_added` (FSEvents on `~/Downloads`) is sufficient — per-browser attribution not worth the cost.
- **No bookmark titles.** Counts only. Title content is forbidden regardless of allow-list (privacy ratchet — bookmark titles are heavily curated by user, much more sensitive than visited URLs).
- **No cookies / form data / autofill / page DOM / screenshots.** Forbidden permanently.
- **No `source of` / `text of` / `do JavaScript` AppleScript.** Forbidden — per-adapter source-grep test fence enforces.
- **No Arc bookmarks watch.** Q4 add-ons selected Arc per-tab nav only.
- **No retroactive history rewrite.** Pre-P3 events stay in DB as-is; P3 filter applies to new events only.

---

## 2. Substrate recap

Full citations in research doc §1. Key facts:

- **Three adapters** in `Packages/LeafCorePrivate/Prod/Collectors/Apple/{ProdSafariAdapter,ProdChromeAdapter,ProdArcAdapter}.swift`. 30 s poll, 1 s timeout. Read `(URL, name) of tabs of front window` + `id of front window`.
- **Three state machines** in `Packages/LeafCore/Sources/LeafCore/OS/{Safari,Chrome,Arc}StateMachine.swift`. URL-set membership diff (order-agnostic). Emit `*_tabs_changed`.
- **Boundary type** `BrowserTab(title, url)` in `Packages/LeafCore/Sources/LeafCore/OS/BrowserTab.swift`. Source-grep tests assert no other field leaks.
- **AppleScript orchestrator** `LeafAgent/Collectors/AppleScriptCollector.swift` — per-adapter `Task` loop with adapter's `pollIntervalSec`. Gates via `LocalAppsStore.isEnabled(bundleID)`.
- **AS permission store** `Packages/LeafCore/Sources/LeafCore/OS/AppleScriptPermissionStore.swift` — UserDefaults-backed (`tech.gundem.leaf` suite), 24h denied-cache, cross-process.
- **FSEvents infra** `Packages/LeafCore/Sources/LeafCore/Collectors/FSEventsCollector.swift` (197 LOC) + `Internal/FSEventStream.swift` (132 LOC). Router signature `(path, flags, watchedFolders, now) → .event(RawEvent) | .filtered | .unknown`. **Bound to user-chosen security-scoped folders** via M003 `watched_folders` — does not fit P3's system-controlled paths.
- **FDA probe** `Leaf/Models/PermissionsService.swift:221` — `defaultFDAProbe()` via `contentsOfDirectory` on `~/Library/Application Support/com.apple.TCC` (read-success ⇒ FDA granted, EPERM ⇒ denied). System Settings deep-link at line 210.
- **Registry** 152 entries in `ShareEventTypeRegistry.swift`. Browser cases at lines 194-196.

---

## 3. Architecture

P3 ships **four** substrate additions and **one** schema migration:

```
                ┌─────────────────────────────────────┐
                │     M026 — browser_domain_allow     │
                │  (domain PK, granularity, added_ts) │
                └────────────────┬────────────────────┘
                                 │
                                 ▼
                    ┌──────────────────────────┐
                    │  DomainAllowListReader   │
                    │   (Sendable; DB-backed)  │
                    └─────┬────────────────┬───┘
                          │                │
        AppleScript path  │                │  FSEvents path
                          ▼                ▼
   ┌──────────────────────────────┐  ┌───────────────────────────┐
   │  Prod{Safari,Chrome,Arc}     │  │ BrowserBookmarksWatcher   │
   │       Adapter (extended)     │  │   (new actor + own         │
   │  - enriched tickScript       │  │    FSEventStream)         │
   │  - parse: TabSnapshot list   │  │  - Chrome: ~/Library/AS/   │
   │  - observe(): runs through 2 │  │    Google/Chrome/**/       │
   │    state machines + filter   │  │    Bookmarks (recursive)   │
   └────────┬─────────────────────┘  │  - Safari: ~/Library/      │
            │                        │    Safari/Bookmarks.plist  │
            ▼                        │    (FDA-gated)            │
   ┌──────────────────────────────┐  │  - emits *_bookmark_       │
   │  Pure state machines (3 ea): │  │    changed with count_     │
   │  - SafariTabsStateMachine    │  │    delta + total_count     │
   │    (existing, filter-input)  │  └───────────────────────────┘
   │  - SafariNavStateMachine     │
   │    (NEW, per-tab map)        │
   │  - SafariActiveStateMachine  │
   │    (NEW, front-tab diff)     │
   │  …Chrome…Arc analogues       │
   │                              │
   │  ALL return [ProtoEvent].    │
   │  Adapter applies filter      │
   │  AFTER state machine.        │
   └────────┬─────────────────────┘
            │
            ▼
       [RawEvent] → EventWriter → events table
```

### 3.1 Component boundaries (per brainstorm tension resolutions)

- **A1 (state machines per-tab).** Three new state machines per browser (tabs / nav / active) — independent value types, no cross-dependency. Pure logic, no DB / no FS access.
- **B2 (filter at adapter wrapper, applied to snapshots BEFORE state machines).** State machines stay pure value types; adapter wrapper holds `DomainAllowListReader` and filters the raw `[TabSnapshot]` from `parse()` **before** feeding into any state machine. State machines then operate on filtered snapshots — their internal logic is unchanged from existing pattern. Proto events emitted by state machines carry already-filtered URLs/titles, mapped 1:1 into `RawEvent`. Privacy gate sits between `parse()` output and state-machine input — one stop closer to the writer than the alternative of filtering at proto-emit time.
- **C1 + refinement (independent bookmarks watcher).** New actor + own `FSEventStream` watching parent dirs **recursively**, filtering callback paths by filename suffix (`Bookmarks` for Chrome, `Bookmarks.plist` for Safari). Handles Chrome multi-profile elegantly; per-browser FDA gate.
- **D1 (filter applied before state-machine input).** Allow-list filter applied to URLs **before** the state machine sees them. As a side-effect, existing `*_tabs_changed` cardinality semantics shift from "URL-set diff" to "domain-set diff" (intra-domain nav between non-allow-listed URLs is invisible to the cardinality machine). Explicit and documented.

### 3.2 New types

```
// Pure value type — substrate, no behavior.
public struct TabSnapshot: Sendable, Hashable, Codable {
    public let tabKey: String     // Chrome: tab.id; Safari/Arc: "i<index>"
    public let title: String      // raw — adapter filters before RawEvent
    public let url: String        // raw — adapter filters before RawEvent
}

// Intermediate emit type from state machines.
public struct ProtoBrowserEvent: Sendable {
    public enum Kind { case tabsChanged, tabNavigated, tabActivated }
    public let kind: Kind
    public let bundleID: String
    public let timestampMs: Int64
    public let activeWindowID: String?
    public let payload: [String: String]   // raw fields, pre-filter
}

// Filter facade — read by adapter wrapper at observe time.
public protocol DomainAllowListReader: Sendable {
    func granularity(for domain: String) -> URLGranularity
}

public enum URLGranularity: String, Sendable {
    case fullUrl = "full_url"
    case pathStripped = "path_stripped"
    case domainOnly = "domain_only"
}
```

Concrete `DBDomainAllowListReader` lives in `LeafCorePrivate` (queries `browser_domain_allow` via GRDB; LRU-cached for tick-cheap reads).

### 3.3 What stays vs what changes

**Stays:**
- `BrowserTab` (used by per-tab state machines via JSON-encoded `tabs` payload field — backward compat).
- `Safari/Chrome/ArcObservation` adapt to wrap new `TabSnapshot` list (extended observation).
- `ProdSafariAdapter.targetBundleIDs / pollIntervalSec / timeoutSec` — unchanged values.
- Existing tests (with fixture updates for D1 filter-before-input semantics — see §13).

**Changes:**
- Adapter `tickScript` reads enriched per-tab data (Chrome: also `id`; all: also `current tab`).
- Adapter `parse` returns enriched observation containing `[TabSnapshot]` + active tab key.
- Adapter `observe` instantiates **three state machines** (tabs / nav / active), applies allow-list filter post-state-machine, emits 0-3 `RawEvent` per tick.
- `SafariStateMachine` / `ChromeStateMachine` / `ArcStateMachine` keep their name + emit semantics but consume **filtered** URLs (D1 consequence; their internal logic untouched).

---

## 4. Schema — M026 `browser_domain_allow`

### 4.1 Table

```sql
CREATE TABLE browser_domain_allow (
    domain TEXT PRIMARY KEY NOT NULL,
    granularity TEXT NOT NULL CHECK (granularity IN ('full_url','path_stripped','domain_only')),
    added_at_ms INTEGER NOT NULL,
    notes TEXT
);
```

- `domain` — host-only (no scheme, no port, no path). Stored lowercased. Subdomain matches exact (`api.github.com` does NOT match `github.com`; user must add both if needed).
- `granularity` — what level of detail this domain permits when matched. Default for new rows on insertion = `full_url`.
- `added_at_ms` — epoch ms; UI sorts most-recent first.
- `notes` — optional user free-text annotation ("work GitHub", "personal banking"). Never leaves the device.

### 4.2 Default behaviour for non-matching domains

When `DomainAllowListReader.granularity(for: "foo.com")` returns no row → treat as `domainOnly` (D3 from research → user choice Q3).

### 4.3 Cold-start posture

Table is empty by default. First tick: every URL becomes `domain_only`. User adds domains via Settings → Privacy → Browser Allow-list (§10). No onboarding template (matches Share Controls default-empty posture per ADR-020).

### 4.4 Migration file

`Packages/LeafCore/Sources/LeafCore/DB/Migrations/M026_BrowserDomainAllow.swift` — pattern mirrors `M003_WatchedFolders.swift`. Registered in `Database.swift` (the file at `Packages/LeafCore/Sources/LeafCore/DB/Database.swift:62` migration block) after `M024` registration:

```swift
migrator.registerMigration026BrowserDomainAllow()
```

Migration body:

```swift
extension DatabaseMigrator {
    mutating func registerMigration026BrowserDomainAllow() {
        registerMigration("026_browser_domain_allow") { db in
            try db.create(table: Schema.BrowserDomainAllow.tableName, ifNotExists: true) { t in
                t.primaryKey(Schema.BrowserDomainAllow.domain, .text)
                t.column(Schema.BrowserDomainAllow.granularity, .text).notNull()
                t.column(Schema.BrowserDomainAllow.addedAtMs, .integer).notNull()
                t.column(Schema.BrowserDomainAllow.notes, .text)
                t.check(sql: "\(Schema.BrowserDomainAllow.granularity) IN ('full_url','path_stripped','domain_only')")
            }
        }
    }
}
```

`Schema.BrowserDomainAllow` namespace added to `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift` matching `Schema.WatchedFolders` shape.

---

## 5. Event kinds — payload shapes

All payloads carry `event_kind` at top level. Field naming: snake_case to match the rest of `events.payload_json`. Privacy-sensitive fields go through the adapter filter (B2 placement).

### 5.1 `safari_tab_navigated` / `chrome_tab_navigated` / `arc_tab_navigated`

```json
{
  "event_kind": "<browser>_tab_navigated",
  "active_window_id": "1234",
  "tab_key": "i3",           // Safari/Arc: "i<index>"; Chrome: stable tab.id
  "previous_url": "github.com",
  "current_url": "github.com/foo/bar",
  "title": "Foo · bar"       // present ONLY if current_url's domain is allow-listed at full_url
}
```

- `tab_key` always present.
- `previous_url` / `current_url` — already filtered by adapter (domain_only / path_stripped / full_url per allow-list).
- `title` — present **only** when filter resolved to `full_url`. Otherwise omitted entirely (not empty-string).
- Both URLs filtered independently — a `path_stripped → full_url` cross-domain nav surfaces as `"github.com/foo" → "linear.app/issue/LEAF-123"`.

### 5.2 `safari_tab_activated` / `chrome_tab_activated` / `arc_tab_activated`

```json
{
  "event_kind": "<browser>_tab_activated",
  "active_window_id": "1234",
  "previous_tab_key": "i2",
  "current_tab_key": "i5",
  "current_url": "github.com",   // filtered same as nav events
  "title": "GitHub"              // present iff full_url
}
```

- Only emits when the **active tab within front window** changes. Front-window switch (different browser window came forward) does NOT emit this — it would emit `_tabs_changed` only if the set differs.
- Activation between two non-allow-listed `github.com` tabs → both `current_url` resolve to `"github.com"` → still emit (different `tab_key` is the signal).

### 5.3 `chrome_bookmark_changed` / `safari_bookmark_changed`

```json
{
  "event_kind": "<browser>_bookmark_changed",
  "total_count": 142,
  "delta": 1,                    // +1 add, -1 remove, 0 reorder/edit
  "profile_label": "Default"     // Chrome multi-profile; Safari omitted
}
```

- **Never titles, never URLs.** Counts and per-profile bucketing only.
- `profile_label` — Chrome derives from `~/Library/Application Support/Google/Chrome/<Profile>/Bookmarks` parent dir name. Safari omits.
- `delta` — sign of `total_count_new - total_count_prev`. Zero delta (reorder / edit / rename) still emits (signal: "you touched your bookmarks").
- Cold tick: no `_changed` emit (seeds count without emission, same posture as existing `*StateMachine` cold-start).

### 5.4 Existing `*_tabs_changed` (unchanged shape, changed semantics)

Payload shape stays: `{event_kind, active_window_id, tabs}` where `tabs` is JSON-encoded `[{title, url}]`. The **content** of `tabs` is now filtered:

- For `domain_only` resolution: `[{title: "", url: "github.com"}, {title: "", url: "linear.app"}]` — title scrubbed, URL collapsed to domain.
- For `path_stripped`: `[{title: "", url: "github.com/path"}]` — title scrubbed, URL keeps path but not query.
- For `full_url`: `[{title: "Foo", url: "github.com/path?q=1"}, ...]` — both surface.
- Note: `title` is `""` when filter resolves below `full_url`, **not** omitted (existing `BrowserTab.title: String` non-optional contract preserved; downstream consumers — ActivityFeedMapper, RelayBodyLeakageTests — already tolerate empty title).
- Cardinality (`tabsCount(payload["tabs"])`) preserved — JSON array length still correct.

---

## 6. AppleScript tickScript changes per adapter

Each adapter's `tickScript` is enriched to read per-tab fields. Output shape encoded as flat AS list for `parse` to deserialise.

### 6.1 Safari

```applescript
tell application "Safari"
    try
        set theWindowID to ""
        set acc to {}
        set currentIndex to 0
        try
            set theWindowID to (id of front window) as string
            set currentIndex to (index of current tab of front window) as integer
            set tabURLs to (URL of tabs of front window) as list
            set tabNames to (name of tabs of front window) as list
            repeat with i from 1 to count of tabURLs
                set end of acc to ("i" & (i as string))           -- tab_key
                set end of acc to (item i of tabNames as string)  -- title
                set end of acc to (item i of tabURLs as string)   -- url
            end repeat
        end try
        return {theWindowID, currentIndex as string, acc}
    on error
        return {"", "0", {}}
    end try
end tell
```

- **No `source`, no `text`, no `do JavaScript`.** Per-adapter source-grep test fence enforces.
- Output triple: `(window_id, current_tab_index_as_string, [tab_key, title, url, tab_key, title, url, ...])`.
- `current_tab_index_as_string` enables `_tab_activated` diff.

### 6.2 Chrome

```applescript
tell application "Google Chrome"
    try
        set theWindowID to ""
        set acc to {}
        set activeID to ""
        try
            if (mode of front window) is "incognito" then
                return {"", "", {}}
            end if
            set theWindowID to (id of front window) as string
            set activeID to (id of active tab of front window) as string
            set tabIDs to (id of tabs of front window) as list
            set tabURLs to (URL of tabs of front window) as list
            set tabNames to (title of tabs of front window) as list
            repeat with i from 1 to count of tabIDs
                set end of acc to (item i of tabIDs as string)
                set end of acc to (item i of tabNames as string)
                set end of acc to (item i of tabURLs as string)
            end repeat
        end try
        return {theWindowID, activeID, acc}
    on error
        return {"", "", {}}
    end try
end tell
```

- **Incognito explicit skip** via `mode of front window` (Chromium dictionary supports this — see research §2.2). Belt-and-suspenders alongside AS-invisibility convention.
- `tab.id` stable across reorder → reliable nav identity.
- `active tab.id` → activation identity. Different from Safari's index-based scheme.

### 6.3 Arc

```applescript
tell application "Arc"
    try
        set theWindowID to ""
        set acc to {}
        set activeID to ""
        try
            set theWindowID to (id of front window) as string
            -- Arc dictionary support is community-variance-prone; both
            -- branches degrade gracefully.
            try
                set activeID to (id of active tab of front window) as string
                set tabIDs to (id of tabs of front window) as list
                set tabURLs to (URL of tabs of front window) as list
                set tabNames to (title of tabs of front window) as list
                repeat with i from 1 to count of tabIDs
                    set end of acc to (item i of tabIDs as string)
                    set end of acc to (item i of tabNames as string)
                    set end of acc to (item i of tabURLs as string)
                end repeat
            end try
        end try
        return {theWindowID, activeID, acc}
    on error
        return {"", "", {}}
    end try
end tell
```

- Same shape as Chrome (Arc is Chromium-based; expected to expose similar properties).
- Outer + inner `try` blocks: outer wraps everything; inner wraps the tab enumeration so a partial AS dictionary (e.g. `id of tabs` not supported) still yields `(window_id, "", [])` — Arc per-tab nav cleanly degrades to S2 cardinality emission via existing `arc_tabs_changed`.

### 6.4 Bundle ID — Arc

`company.thebrowser.Browser` (verified existing in registry, line 196 share key + `ProdArcAdapter`).

---

## 7. State machines (per-browser × 3 kinds)

### 7.1 Existing `Safari/Chrome/ArcStateMachine` — unchanged

Inputs change (D1 filter-before-input → state machines now see filtered URLs), internals untouched. Cardinality semantics shift from URL-set to domain-set diff for non-allow-listed.

### 7.2 New `<Browser>NavStateMachine` (per-tab nav)

```swift
public struct SafariNavStateMachine: Sendable {
    private var prevTabUrls: [String: String]?   // tab_key → url

    public init() {}

    public mutating func observe(
        _ snapshots: [TabSnapshot],
        windowID: String?,
        nowMs: Int64
    ) -> [ProtoBrowserEvent] {
        defer { prevTabUrls = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.tabKey, $0.url) }) }
        guard let prev = prevTabUrls else { return [] }   // cold-tick seed only
        var emits: [ProtoBrowserEvent] = []
        for snap in snapshots {
            guard let prevURL = prev[snap.tabKey], prevURL != snap.url else { continue }
            emits.append(.tabNavigated(
                bundleID: "com.apple.Safari",
                tabKey: snap.tabKey,
                previousURL: prevURL,
                currentURL: snap.url,
                rawTitle: snap.title,
                activeWindowID: windowID,
                nowMs: nowMs
            ))
        }
        return emits
    }
}
```

- Cold tick: `prevTabUrls == nil` → seed, no emit. Subsequent ticks compare.
- New tabs (key in current, not in prev) → no nav emit (the tab is new, not navigated). It surfaces only via `_tabs_changed` cardinality.
- Closed tabs (key in prev, not in current) → no emit. Tab gone, not "navigated to nothing."
- Per-tab URL change with same key → nav emit.
- **Safari quirk:** tab close at index N causes tabs N+1..M to shift up by one index; with positional `i<N>` key strategy, this appears as multiple false navs. Acceptable lossy semantics — see §1.3 substrate honesty. Mitigation in plan: surface as known limitation in Activity feed UI ("Safari nav events may double-count after closing a non-rightmost tab").

`ChromeNavStateMachine` and `ArcNavStateMachine` follow same shape but use real `tab.id` as key — no positional drift.

### 7.3 New `<Browser>ActiveStateMachine` (per-tab activation)

```swift
public struct SafariActiveStateMachine: Sendable {
    private var prevActive: (windowID: String, tabKey: String)?

    public mutating func observe(
        currentTabKey: String,
        currentURL: String,
        rawTitle: String,
        windowID: String?,
        nowMs: Int64
    ) -> [ProtoBrowserEvent] {
        let prev = prevActive
        defer {
            if let wid = windowID {
                prevActive = (wid, currentTabKey)
            }
        }
        guard let p = prev, let wid = windowID else { return [] }   // cold + no-window
        guard p.windowID != wid || p.tabKey != currentTabKey else { return [] }
        return [.tabActivated(...)]
    }
}
```

- Diffs `(windowID, tabKey)` pair across ticks.
- Window switch alone → emit (different `windowID`, current_tab_key now belongs to a different window).
- No-window-id state (browser closed mid-tick) → no emit; resume on next valid tick.

### 7.4 Adapter wiring all three state machines

```swift
public func observe(
    _ observation: any AdapterObservation,
    nowMs: Int64,
    localAppsStore: LocalAppsStore
) -> [RawEvent] {
    guard let obs = observation as? SafariObservation else { return [] }
    // B2: filter snapshots BEFORE state machines.
    let reader = allowListReader  // injected at adapter construction
    let filteredSnaps = obs.snapshots.map { snap -> TabSnapshot in
        let granularity = reader.granularity(for: extractDomain(snap.url))
        return TabSnapshot(
            tabKey: snap.tabKey,
            title: granularity == .fullUrl ? snap.title : "",
            url: applyGranularity(snap.url, granularity)
        )
    }
    // Run all three state machines (each is a stored property in StateMachineBox).
    return stateMachineBox.observe(
        filteredSnaps: filteredSnaps,
        windowID: obs.activeWindowID,
        currentTabIndex: obs.currentTabIndex,
        nowMs: nowMs
    )
}
```

- **One filter pass, three state machine consumers.** Filter doesn't repeat per state machine.
- Domain extraction (`extractDomain`) uses URLComponents → host lowercased. IPv6 / userinfo / port stripped.
- Granularity application:
  - `fullUrl` → URL unchanged
  - `pathStripped` → `host + path`, no query / fragment
  - `domainOnly` → `host` only

`StateMachineBox` exposes a single `observe(...)` method that runs all three machines and concatenates their `ProtoBrowserEvent` output, then maps each proto to `RawEvent`.

---

## 8. Bookmarks watcher (Chrome + Safari, FDA-gated for Safari)

### 8.1 New collector

```swift
public actor BrowserBookmarksWatcher {
    private let writer: EventWriter
    private let logger: Logger
    private let chromeStream: FSEventStream?
    private let safariStream: FSEventStream?
    private var chromeCounts: [String: Int] = [:]   // profile_label → count
    private var safariCount: Int? = nil
    private let chromeRoot = NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
    private let safariPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"

    public init(writer: EventWriter, permissions: PermissionsService, logger: Logger) async {
        // ...
    }

    public func start() async { ... }
    public func stop() async { ... }
}
```

- **Two streams in one collector** (Chrome + Safari). One actor for both — single lifetime.
- **Chrome stream** watches `~/Library/Application Support/Google/Chrome/` recursively with `kFSEventStreamCreateFlagFileEvents`. Callback filters paths matching `*/Bookmarks` (no extension; Chrome's literal filename).
- **Safari stream** watches `~/Library/Safari/` (single file `Bookmarks.plist` — watch the parent dir to avoid stream invalidation on Safari's atomic rewrite).
- **FDA gate**: at construction, `permissions.fdaProbe()` → if denied, `safariStream` stays nil and a `BrowserBookmarksWatcherFeatureState.safariFDADenied = true` flag is written for Settings UI.

### 8.2 Count derivation

- **Chrome `Bookmarks`** — JSON. Walk `roots.bookmark_bar.children + roots.other.children + roots.synced.children` recursively, sum leaf nodes (`type == "url"`). Folders not counted. Read with `Data(contentsOf:)` + `JSONSerialization`. Failure (file in mid-write) → skip this tick.
- **Safari `Bookmarks.plist`** — binary plist. Walk `Children` recursively, count `WebBookmarkType == WebBookmarkTypeLeaf`. Failure → skip.

### 8.3 Emit semantics

```
on FSEvent fired for path P matching pattern:
    new_count = derive_count(P)
    profile = extract_profile_label(P)             // Chrome only
    prev_count = self.chromeCounts[profile] ?? nil   // or self.safariCount
    if prev_count != nil:
        emit *_bookmark_changed(
            total_count: new_count,
            delta: new_count - prev_count,
            profile_label: profile  // omitted for Safari
        )
    self.chromeCounts[profile] = new_count          // or self.safariCount = new_count
```

- Cold tick (no prev): seed, no emit.
- Multiple events in a tick: collapse via FSEventStream latency parameter (1.5 s) — file-event coalescing handles rapid bookmark add/remove.

### 8.4 FDA UX

- **Toggle in Settings → System Observers** ("Safari bookmarks (requires Full Disk Access)").
- Toggle ON → call `permissions.requestFDAInstructions()` which:
  - Probes FDA via `defaultFDAProbe()`.
  - If denied → open System Settings deep-link (`x-apple.systempreferences:com.apple.preference.security?FullDiskAccess`) and show inline "After granting, restart Leaf" hint.
- After FDA granted + Leaf restart → watcher initialises Safari stream successfully on next start.
- **No periodic re-probe** — FDA grant is sticky until user revokes (system event; user has full control).

### 8.5 Backward compat

No existing bookmarks collector. Net-new path. No tests to update; new tests added per §13.

---

## 9. Allow-list filter — pipeline details

### 9.1 Domain extraction

```swift
func extractDomain(_ urlString: String) -> String {
    guard let comps = URLComponents(string: urlString),
          let host = comps.host?.lowercased() else { return "" }
    return host
}
```

- IPv6 hosts retained as-is (rare in browser navigation).
- Empty host (e.g. `about:blank`, `chrome://settings`) → `""`. Empty domain matches no allow-list row → defaults to `domainOnly` (which on empty domain effectively returns empty URL).
- IDN / Punycode: preserve whatever URLComponents returns. User adds the form they see in browser. (URLComponents normalises to Punycode for IDN.)

### 9.2 Subdomain matching

**Exact match only.** `api.github.com` ≠ `github.com`. User-determined; no fuzzy match. Future expansion (eTLD+1 fallback) deferred.

### 9.3 Granularity application

```swift
func applyGranularity(_ urlString: String, _ g: URLGranularity) -> String {
    guard let comps = URLComponents(string: urlString),
          let host = comps.host?.lowercased() else { return "" }
    switch g {
    case .fullUrl:
        return urlString
    case .pathStripped:
        let path = comps.path
        return path.isEmpty ? host : host + path
    case .domainOnly:
        return host
    }
}
```

- `host + path` for `pathStripped` — query and fragment dropped. Sensitive (oauth tokens often in fragment) → never preserved at this level.
- `domainOnly` returns `host` (e.g. `"github.com"`). No `://` prefix.

### 9.4 Reader caching

`DBDomainAllowListReader` (LeafCorePrivate) caches the table in an LRU dict per actor:

- Reload trigger: explicit `invalidate()` call from Settings UI when user adds/removes domain.
- TTL: none (manual invalidation only).
- Worst case: stale cache for 30s tick → at most one tick's events use old granularity. Acceptable.
- Initial population: lazy on first `granularity(for:)` call.

---

## 10. Settings UI changes

Per contract §8, P3 surfaces two UI changes — both in existing screens.

### 10.1 Settings → System Observers (Track-4 S3 surface)

Three new toggle rows added below existing observers:

- **"Browser bookmarks — Chrome"** (default OFF)
  - Sub-explanation: "Tracks count of bookmarks (no titles, no URLs)."
- **"Browser bookmarks — Safari"** (default OFF, requires Full Disk Access)
  - Sub-explanation: "Tracks count of bookmarks. Requires Full Disk Access in System Settings."
  - If toggle attempted ON with FDA denied: inline alert with "Open System Settings" button → deep-link to FDA pane.
  - Status pill: "Active" / "FDA denied — [Open Settings]" / "Off".

Implementation: extends existing System Observers SwiftUI screen with three rows; binds to `LocalAppsStore` sub-field keys (`browser_bookmarks_chrome`, `browser_bookmarks_safari`). The watcher's `start()` is gated on these keys.

### 10.2 Settings → Privacy → Browser Allow-list (new screen)

New screen under Settings → Privacy section. List view of `browser_domain_allow` rows.

```
┌───────────────────────────────────────────────────────────┐
│  Browser Allow-list                          [+ Add Domain]│
│                                                            │
│  Domains here capture full URLs and page titles when you  │
│  visit them. All other domains capture only the domain   │
│  name. Default: empty (everything is domain-only).        │
│                                                            │
│  ────────────────────────────────────────────────────────  │
│  github.com         [Full URL]      [Notes: work GitHub]  │
│  linear.app         [Full URL]      [Notes: ]             │
│  example.com        [Path only]     [Notes: ]             │
│  ────────────────────────────────────────────────────────  │
│                                                            │
└───────────────────────────────────────────────────────────┘
```

- "Add Domain" → modal with `domain` field (auto-lowercased on input), `granularity` Picker (Full URL / Path only / Domain only — explanatory text per option), optional `notes`.
- Per-row right-click / swipe: Edit / Delete.
- Save triggers `DBDomainAllowListReader.invalidate()`.

UI lives in `Leaf/Views/Settings/Privacy/BrowserAllowListView.swift` (new file). Binds via `BrowserAllowListStore` (new ObservableObject; reads/writes M026 table via Database access layer). 

### 10.3 Settings → Local Apps — no change

Safari / Chrome / Arc Local Apps toggles already exist (Track-4 S2). They control the AppleScript adapter on/off. **P3's per-tab nav + activation events ride on the existing Local Apps toggle** — no new sub-toggle. ShareEventTypeKey gates the individual event_kinds for relay broadcast (separate downstream filter); the AS adapter still emits to local DB when the app toggle is ON.

Implication: if user enables "Safari" in Local Apps but disables all six tab-nav-related share keys, events still land in local DB but never broadcast. Matches existing Track-3 / Track-4 ShareEventTypeKey gate posture.

---

## 11. ActivityFeedMapper extension

`Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift:mapLocalOS` switch gains 8 new cases. Pattern mirrors existing browser cases at lines 628-633.

### 11.1 Case bodies

```swift
case "safari_tab_navigated":
    let curr = payload["current_url"] ?? "?"
    primary = "Safari: \(curr)"
    secondary = "navigated"
case "chrome_tab_navigated":
    primary = "Chrome: \(payload["current_url"] ?? "?")"
    secondary = "navigated"
case "arc_tab_navigated":
    primary = "Arc: \(payload["current_url"] ?? "?")"
    secondary = "navigated"

case "safari_tab_activated":
    primary = "Safari: \(payload["current_url"] ?? "?")"
    secondary = "tab activated"
case "chrome_tab_activated":
    primary = "Chrome: \(payload["current_url"] ?? "?")"
    secondary = "tab activated"
case "arc_tab_activated":
    primary = "Arc: \(payload["current_url"] ?? "?")"
    secondary = "tab activated"

case "chrome_bookmark_changed":
    let delta = payload["delta"].flatMap { Int($0) } ?? 0
    primary = "Chrome bookmarks: \(deltaText(delta)) (\(payload["total_count"] ?? "?") total)"
case "safari_bookmark_changed":
    let delta = payload["delta"].flatMap { Int($0) } ?? 0
    primary = "Safari bookmarks: \(deltaText(delta)) (\(payload["total_count"] ?? "?") total)"
```

- Primary text shows the **filtered URL** (already domain-only or path-stripped or full per allow-list).
- Secondary text = the verb. No URL leaks via primary text into Activity feed beyond what filter allowed.
- `deltaText(delta)` returns `"+1"` / `"-1"` / `"updated"` (for delta = 0).

### 11.2 Skip-list registration

All 8 new event_kinds added to `trackFourLocalOSKinds` constant set in `ActivityFeedMapper.swift` (Track-4 S4 dispatcher pattern).

### 11.3 EventKindIcon mapping

`Packages/LeafCore/Sources/LeafCore/Insights/EventKindIcon.swift` — add SF Symbol mapping for 8 new event_kinds. Pattern: per-browser brand icon (Safari → `safari`, Chrome → `globe`, Arc → `arc.up.right`). Nav → `arrow.right.circle`. Activation → `rectangle.stack`. Bookmark → `bookmark`.

### 11.4 Body-kind dispatcher (Track-4 S4 carry-over)

Browser events do **not** introduce FTS-indexable body content. Page titles for `full_url` allow-listed domains exist in payload `title` but are **not** routed to `events_fts`. Rationale: titles are not durable search anchors (same page navigates to same title repeatedly), and indexing them widens the privacy surface unnecessarily. Same posture as current `*_tabs_changed`. Body-kind dispatcher pattern (`(payloadKey, bodyKind)?`) returns `nil` for all P3 event_kinds.

---

## 12. ShareEventTypeKey deltas

`Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` — append 8 cases after line 196 in a new `// MARK: - Phase Track-6 P3 (Browsers Deep)` section:

```swift
case safariTabNavigated   = "safari_tab_navigated"
case chromeTabNavigated   = "chrome_tab_navigated"
case arcTabNavigated      = "arc_tab_navigated"
case safariTabActivated   = "safari_tab_activated"
case chromeTabActivated   = "chrome_tab_activated"
case arcTabActivated      = "arc_tab_activated"
case chromeBookmarkChanged = "chrome_bookmark_changed"
case safariBookmarkChanged = "safari_bookmark_changed"
```

`ShareEventTypeDefaults.all` — append matching 8 entries after line 411, all `defaultEnabled: false`:

```swift
.init(key: .safariTabNavigated,    defaultEnabled: false),
.init(key: .chromeTabNavigated,    defaultEnabled: false),
.init(key: .arcTabNavigated,       defaultEnabled: false),
.init(key: .safariTabActivated,    defaultEnabled: false),
.init(key: .chromeTabActivated,    defaultEnabled: false),
.init(key: .arcTabActivated,       defaultEnabled: false),
.init(key: .chromeBookmarkChanged, defaultEnabled: false),
.init(key: .safariBookmarkChanged, defaultEnabled: false),
```

Registry-count assertion in `ShareEventTypeRegistry*Tests.swift` bumped from `152` to `160`.

Per-adapter `eventKinds: Set<ShareEventTypeKey>` declarations updated:

- `ProdSafariAdapter`: `[.safariTabsChanged, .safariTabNavigated, .safariTabActivated]`
- `ProdChromeAdapter`: `[.chromeTabsChanged, .chromeTabNavigated, .chromeTabActivated]`
- `ProdArcAdapter`: `[.arcTabsChanged, .arcTabNavigated, .arcTabActivated]`

`BrowserBookmarksWatcher` declares its own `eventKinds` (`[.chromeBookmarkChanged, .safariBookmarkChanged]`) via a side-channel registration that `ShareEventTypeRegistrySnapshot` test can pick up. Pattern lookup happens in plan-stage.

---

## 13. Tests

### 13.1 New tests per file

| File | Adds |
|---|---|
| `SafariStateMachineTests.swift` | **+2 tests** for D1 semantics shift: `testEmitOnSameURLSetDifferentDomainsFails_AllowListEmpty` (domain-set diff), `testEmitWhenAllowListInjectsFullURL_PathsDifferent` |
| `ChromeStateMachineTests.swift` | **+2 tests** (analogous) |
| `ArcStateMachineTests.swift` | **+2 tests** (analogous) |
| `SafariNavStateMachineTests.swift` (NEW) | **+5 tests** cold-tick, nav same key, new tab no-emit, closed tab no-emit, position-shift quirk |
| `ChromeNavStateMachineTests.swift` (NEW) | **+5 tests** analogous, stable `tab.id` semantics |
| `ArcNavStateMachineTests.swift` (NEW) | **+5 tests** analogous + graceful degrade test |
| `SafariActiveStateMachineTests.swift` (NEW) | **+4 tests** cold, window-switch, tab-switch-within-window, no-window |
| `ChromeActiveStateMachineTests.swift` (NEW) | **+4 tests** |
| `ArcActiveStateMachineTests.swift` (NEW) | **+4 tests** |
| `BrowserAllowListFilterTests.swift` (NEW) | **+8 tests** extractDomain edge cases + granularity application + reader cache invalidation |
| `BrowserBookmarksWatcherTests.swift` (NEW) | **+6 tests** Chrome single-profile, Chrome multi-profile, Safari count derive, Safari FDA-denied skip, FSEvent coalescing, cold-tick no-emit |
| `RelayBodyLeakageTests.swift` | **+8 tests** sentinel-leak walkback per new event_kind (mirror existing `assertS2DoesNotLeak` pattern at lines 1617-1655) |
| `ActivityFeedMapperLocalOSTests.swift` | **+8 tests** primary/secondary text per new event_kind |
| `ShareEventTypeRegistryS2Tests.swift` (or successor) | **+8 cases** for new keys |
| `DispatchCoverageTests.swift` | **+8 cases** parity fence per new event_kind in mapLocalOS switch |
| `M026_BrowserDomainAllow.Tests.swift` (NEW) | **+3 tests** schema correctness, CHECK constraint enforcement, default-empty behavior |
| `AdapterSourceGrepTests.swift` (existing per-adapter file-grep tests) | **+3 assertions** per adapter — new `tickScript` lacks `source of`, `text of`, `do JavaScript`, `cookies` literals |

Total: **~80 new test cases** + ~20 fixture updates in existing tests. Plan-stage breaks this into per-commit chunks.

### 13.2 Test-double posture

- **State machines** — pure value types, tested without DI.
- **Adapters** — tested with `InMemoryAllowListReader` (test double).
- **`BrowserBookmarksWatcher`** — actor under test; inject `MockFSEventStream` + `MockEventWriter` + `MockPermissionsService`.
- **Migration M026** — GRDB in-memory `Database` fixture; same pattern as M003-M018 tests.

### 13.3 Cold-vs-warm tick test pattern

Each new state machine + watcher has a `testColdTick_SeedsWithoutEmit` test + `testWarmTick_EmitsOnChange` test. Matches Track-4 S4 / Track-3 D3 coverage discipline.

---

## 14. Privacy walkbacks — `RelayBodyLeakageTests`

Per Track-6 contract §2.4 and §7, every new event_kind needs a sentinel-leak regression test. Pattern mirrors existing browser block (lines 1617-1655 of `RelayBodyLeakageTests.swift`).

### 14.1 Test shape per event_kind

```swift
func testRelayDoesNotLeakSafariTabNavigated_P3() throws {
    try assertS2DoesNotLeak(
        eventKind: "safari_tab_navigated",
        extraPayload: [
            "tab_key": "i3",
            "previous_url": "github.com",
            "current_url": "github.com/foo",
            "title": "Foo",
            "cookies": "SECRET-SAFARI-NAV-COOKIES-P3",
            "source": "SECRET-SAFARI-NAV-SOURCE-P3",
            "history": "SECRET-SAFARI-NAV-HISTORY-P3",
            "form_data": "SECRET-SAFARI-NAV-FORM-P3",
            "autofill": "SECRET-SAFARI-NAV-AUTOFILL-P3"
        ],
        markers: [
            "SECRET-SAFARI-NAV-COOKIES-P3",
            "SECRET-SAFARI-NAV-SOURCE-P3",
            "SECRET-SAFARI-NAV-HISTORY-P3",
            "SECRET-SAFARI-NAV-FORM-P3",
            "SECRET-SAFARI-NAV-AUTOFILL-P3"
        ],
        collectorID: "applescript_safari"
    )
}
```

Eight new tests (one per new event_kind), each injecting sentinels for `cookies`, `source`, `history`, `form_data`, `autofill`, plus `screen_recording` for paranoia. Markers walked through `presence_state.state_json` assertion.

### 14.2 Allow-list bypass regression

Two additional tests verify the filter cannot be bypassed via crafted payload fields:

```swift
func testAllowListFilterNotBypassedViaCraftedPayload_P3() throws
func testRelayDoesNotLeakUnfilteredURLViaTitlePassthrough_P3() throws
```

Both inject "real-looking" URLs in fields the filter shouldn't have touched (e.g. `previous_url` that bypassed extraction) and assert the filter's authority — only filter-allowed values reach `presence_state`.

### 14.3 Adapter source-grep fence

`AdapterSourceGrepTests.swift` (existing or new) — per-adapter assertion that `ProdSafariAdapter.swift` / `ProdChromeAdapter.swift` / `ProdArcAdapter.swift` source files do NOT contain `source of`, `text of`, `do JavaScript`, `cookies`, `localStorage`, `history` literals. Track-4 S2 discipline carried forward.

---

## 15. Backward compat & migration story

### 15.1 In-DB events from before P3

Stay as-is. Pre-P3 `*_tabs_changed` events carry unfiltered URLs/titles in `payload_json.tabs`. We do not rewrite history.

ActivityFeedMapper reads either shape via existing `tabsCount` (cardinality only). Pre-P3 events render with same primary text as post-P3 events with `domain_only` granularity — visual parity (cardinality identical).

### 15.2 Existing user installs

Upon P3 release:

- M026 migration runs, creates empty `browser_domain_allow` table.
- Existing Safari/Chrome/Arc tab capture continues at S2 cadence (30 s tick).
- **Filter applies from first tick post-upgrade.** New events use new semantics.
- Setting → Privacy → Browser Allow-list screen appears empty; user manually adds domains.

No data migration needed. No prompts on upgrade beyond existing Local Apps state.

### 15.3 Release note (downstream)

**One-line user-facing message** (Privacy & Onboarding email / changelog):

> *"Browser URLs are now domain-only by default for stronger privacy. To capture full URLs for a specific site (e.g. work GitHub), add it to Settings → Privacy → Browser Allow-list."*

Whitepaper sync per contract §10 — depth-parity ambition is public-safe; per-domain allow-list pattern is public-safe; exact M026 schema + FSEvents path patterns + AS dictionary entries stay moat.

### 15.4 Test fixture updates

Existing `SafariStateMachineTests` / `ChromeStateMachineTests` / `ArcStateMachineTests` (9 tests total) updated to inject `InMemoryAllowListReader` (default empty → domain-only) into their adapter-under-test, OR moved to test the state machines directly with filtered inputs (depends on which layer the tests own — confirmed in Stage 5 TDD).

---

## 16. Open mini-questions deferred to plan stage

These do not block spec → plan transition. Resolved in Stage 4 writing-plans:

- **Q-plan-1.** Exact `Schema.BrowserDomainAllow` namespace key naming (`tableName`, `domain`, `granularity`, `addedAtMs`, `notes`).
- **Q-plan-2.** Whether `DBDomainAllowListReader` lives in `LeafCorePrivate` (moat — SQL bodies) or in `LeafCore` (public protocol + thin GRDB query — debatable).
- **Q-plan-3.** Chrome `mode of front window` semantics for non-default windows — does AS dictionary expose mode for incognito-only secondary windows? If unreliable, fall back to AS-invisibility convention (skip explicit `mode` check; trust OS).
- **Q-plan-4.** Whether bookmark count derivation should debounce repeated FSEvent fires for same path within 5s (Chrome writes its `Bookmarks` atomically via temp file + rename; one bookmark add typically fires 2 FSEvents — kFSEventStreamEventFlagItemRemoved on temp + ItemRenamed on final). Likely yes; pattern matches FSEventsCollector `latencySec` parameter.
- **Q-plan-5.** Initial `eventKinds` set for `BrowserBookmarksWatcher` — does the watcher own these two keys in `ShareEventTypeKey` lookup, or do they live in a separate "FSEvents-only" surface? Affects how `ShareEventTypeRegistrySnapshot` (if it exists) enumerates them.
- **Q-plan-6.** Whether `prev_active_url` field in `*_tab_activated` payload is useful or redundant given `previous_tab_key`. Default to omit — `previous_tab_key` alone is the activation identity.
- **Q-plan-7.** Naming: `tabsChanged` vs `tabSetChanged` for the existing event_kind. Stays at `_tabs_changed` (no rename — breaking change unjustified).
- **Q-plan-8.** Whether to emit `_tab_activated` when only `windowID` changed but `tabKey` is the same in the new front window (legitimately a "switched browser window" event). Default: yes, emit. Two consecutive windows showing same-named-key tab is rare enough not to need suppression.

---

## 17. Estimated registry delta & schema delta — final

- **ShareEventTypeKey:** 152 → 160 (8 net-new, all default OFF).
- **Schema migrations:** M001..M018 + M024 (P1) → M001..M018 + M024 + **M026 (P3, this spec)**. M019-M023 reserved for Track-5; M025 for P2.
- **Tables:** 28 → **29** (M026 adds `browser_domain_allow`).
- **MCP tools:** unchanged (P3 doesn't add new tools per contract §4).

---

## 18. Acceptance criteria (per contract §2 fitness function)

P3 ships and is **done** when:

1. **Ceiling-mapped.** Research doc (committed) documents AS-only choice + rejected mechanisms.
2. **Event vocabulary lands.** 8 new event_kinds emit under realistic load (manual smoke on author's Mac — see §19).
3. **Parser correctness.** Per-adapter tickScript tolerates: AS dictionary partial response (Arc), cold-start race, locale variants (English literals universal — research §8), private/incognito invisibility.
4. **Privacy contract preserved.** `RelayBodyLeakageTests` extended +8 tests + 2 bypass-regression tests pass. Source-grep fence extended.
5. **Share Controls.** Registry 152 → 160 default OFF.
6. **Smoke verified.** Manual run on author's Mac (§19).

---

## 19. Manual smoke (acceptance gate)

**Author's Mac, post-implementation:**

- **A. Per-tab nav signal.**
  - Open Safari with 3 tabs (github.com/foo, github.com/bar, linear.app/issue).
  - Wait 30 s tick.
  - Navigate tab 1 from `github.com/foo` to `github.com/baz`.
  - Wait 30 s tick.
  - Query DB: `sqlite3 events.sqlite "SELECT payload_json FROM events WHERE payload_json LIKE '%tab_navigated%' ORDER BY id DESC LIMIT 3"`.
  - Expect: one row `safari_tab_navigated` with `previous_url: "github.com"`, `current_url: "github.com"` (domain-only default; allow-list empty).
- **B. Allow-list activation.**
  - Settings → Privacy → Browser Allow-list → Add `github.com` Full URL.
  - Wait 30 s tick. Navigate tab 1 to `github.com/qux`.
  - Wait 30 s. Query DB.
  - Expect: `safari_tab_navigated` with `previous_url: "github.com/baz"`, `current_url: "github.com/qux"`, `title: "<page title>"`.
- **C. Chrome incognito invisibility.**
  - Open Chrome incognito window.
  - Wait 30 s. Query DB.
  - Expect: zero `chrome_tab_*` rows for incognito tabs (AS-invisibility convention + explicit `mode` check).
- **D. Chrome multi-profile bookmark.**
  - Open Chrome in default profile, add a bookmark.
  - Wait 5 s.
  - Query DB.
  - Expect: `chrome_bookmark_changed` row with `delta: 1`, `profile_label: "Default"`.
  - Switch to "Profile 1", add a bookmark.
  - Wait 5 s. Query.
  - Expect: another row with `profile_label: "Profile 1"`.
- **E. Safari FDA flow.**
  - Toggle Safari bookmarks ON in System Observers.
  - On first denial: System Settings deep-link opens FDA pane.
  - Grant FDA, restart Leaf.
  - Add a bookmark in Safari.
  - Wait 5 s. Query.
  - Expect: `safari_bookmark_changed` row.
- **F. Privacy walkback.**
  - `grep -nE "cookies|source|text of|do JavaScript|history" Packages/LeafCorePrivate/Prod/Collectors/Apple/{ProdSafariAdapter,ProdChromeAdapter,ProdArcAdapter}.swift` → 0 hits.
  - `presence_state.state_json` after one tick of capture (from real browsing) shows no URLs / titles / domains leaked through `presence_state`.

---

## 20. References

- Phase contract: `docs/superpowers/specs/2026-05-15-track-6-existing-surface-depth-contract.md`
- Research companion: `docs/superpowers/specs/2026-05-16-track-6-P3-browsers-research.md`
- P1 precedent (spec shape): `docs/superpowers/specs/2026-05-15-track-6-P1-claude-code-deep.md`
- Architecture: `.claude/shared/architecture.md` (Layer A — AS / FSEvents / Share Controls)
- Current-state: `.claude/shared/current-state.md` (Track-4 S2/S3/S4 carry-overs)
- ADR-010 / Won't-list: whitepaper `~/Desktop/Leaf/leaf-docs/docs/privacy-security/wont-list.md`
- ADR-020 Share Controls: whitepaper `~/Desktop/Leaf/leaf-docs/docs/team-sharing/share-controls.md`
