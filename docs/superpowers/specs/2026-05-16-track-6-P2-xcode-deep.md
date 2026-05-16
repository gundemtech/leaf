# Track 6 P2 — Xcode Deep · Design Spec

**Stage:** Stage 3 (Spec) — input to writing-plans
**Contract:** [`2026-05-15-track-6-existing-surface-depth-contract.md`](./2026-05-15-track-6-existing-surface-depth-contract.md)
**Research:** [`2026-05-16-track-6-P2-xcode-deep-research.md`](./2026-05-16-track-6-P2-xcode-deep-research.md)
**Date:** 2026-05-16
**Owner:** Dmitrii (Claude session)
**Branch:** `feature/track-6-P2-xcode-deep` (off `main` @ `9b2a53b`)
**Approach:** A — FSEvents + state-machine split

---

## 1. TL;DR

Track-4 S2 ships a 60s AppleScript poll of Xcode that captures `xcode_active_doc_changed` and `xcode_build_state_changed` at L4. P2 layers **6 new event_kinds** on top — `build_started`, `build_finished`, `test_run_started`, `test_run_finished`, `scheme_changed`, `run_destination_changed` — via three mechanisms:

1. **AppleScript depth extension.** Extend `ProdXcodeAdapter.tickScript` to also fetch `active run destination.name`. Existing `XcodeStateMachine` stays untouched; a new sibling `XcodeBuildLifecycleStateMachine` consumes the enriched observation and emits build-lifecycle + scheme + run-destination transitions.
2. **FSEvents on DerivedData.** A new `DerivedDataFSEventsWatcher` subscribes to `~/Library/Developer/Xcode/DerivedData/` and detects `xcresult` bundle creation in `Logs/Test/` and `Logs/Launch/`. Emits `test_run_started` on directory creation and `test_run_finished` after the bundle's `Info.plist` is written.
3. **xcresulttool enrichment.** A new `XcresultStructuredSummaryParser` shells out to `xcrun xcresulttool get build-results|test-results summary --legacy --path <bundle>` (5s timeout) and parses the structured JSON. Used to enrich `build_finished` (errorCount/warningCount/targetName) and `test_run_finished` (passed/failed/skipped counts).

No new SQLCipher table. M025 reservation released to the next phase. ShareEventTypeKey registry +6 (default OFF). Privacy walkbacks per ADR-010 — `errors[].message`, `errors[].sourceURL`, `destination.deviceName`, individual test method names, build log content all stripped before emit; `destination.deviceName` bucketed to `macos | ios_simulator | ios_device | tv | watch | vision`.

---

## 2. New event_kinds (canonical schemas)

All payloads are `[String: String]`. Field order in `event_kind` is canonical; optional fields elided when probe fails.

### 2.1 `xcode_build_started`
- **Trigger:** AppleScript `last scheme action result.status` flips from `not yet started | succeeded | failed | cancelled` to `running`.
- **Mechanism:** `XcodeBuildLifecycleStateMachine` via `ProdXcodeAdapter` tick.
- **Payload:**
  - `event_kind` = `xcode_build_started`
  - `scheme` — current active scheme name (optional, omitted if missing-value)
  - `project` — workspace document name (optional)
  - `run_destination_bucket` — bucketed enum: `macos | ios_simulator | ios_device | tv | watch | vision | unknown`
- **Cadence:** at most once per 60s tick per build trigger.

### 2.2 `xcode_build_finished`
- **Trigger:** AppleScript status flips from `running` to `succeeded | failed | cancelled`.
- **Mechanism:** `XcodeBuildLifecycleStateMachine`. If a sibling xcresult bundle exists in `DerivedData/<hash>/Logs/Launch/` mtime'd within ±5s of the finish detection, the watcher path enriches the same event_kind with structured counts via xcresulttool.
- **Payload:**
  - `event_kind` = `xcode_build_finished`
  - `status` — enum: `succeeded | failed | cancelled`
  - `duration_ms` — finish_ts − last build_started_ts (machine-tracked)
  - `scheme`, `project`, `run_destination_bucket` — same as `build_started`
  - `error_count` — present only if xcresult enrichment succeeded (Int as string)
  - `warning_count` — same
  - `analyzer_warning_count` — same
  - `target_names_count` — Int as string; count of distinct targetName values in `errors[]` (cardinality only, not raw names — names go to L4 `target_name_top` only if exactly one)
  - `target_name_top` — present only when distinct count == 1 (single target failed)

### 2.3 `xcode_test_run_started`
- **Trigger:** FSEvents `kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir` on path matching `~/Library/Developer/Xcode/DerivedData/*/Logs/Test/*.xcresult`.
- **Mechanism:** `DerivedDataFSEventsWatcher` callback → `XcodeTestRunStateMachine`.
- **Payload:**
  - `event_kind` = `xcode_test_run_started`
  - `scheme` — derived from `LogStoreManifest.plist` sibling lookup if available (best-effort)
  - `run_destination_bucket` — best-effort from xcresult's Info.plist destination probe; `unknown` if bundle not yet readable

### 2.4 `xcode_test_run_finished`
- **Trigger:** FSEvents `kFSEventStreamEventFlagItemModified` on `<xcresult>/Info.plist` AFTER stable-write detection (≥1s since last mutation, max 30s wait).
- **Mechanism:** `DerivedDataFSEventsWatcher` → invoke `XcresultStructuredSummaryParser` synchronously → `XcodeTestRunStateMachine`.
- **Payload:**
  - `event_kind` = `xcode_test_run_finished`
  - `passed_count` — Int as string
  - `failed_count` — Int as string
  - `skipped_count` — Int as string
  - `expected_failure_count` — Int as string (Swift Testing concept)
  - `total_count` — Int as string
  - `duration_ms` — from xcresult endTime − startTime
  - `scheme` — from xcresult metadata
  - `run_destination_bucket`
  - `status` — derived: `succeeded` if failed_count == 0, `failed` otherwise (no `cancelled` for tests in xcresult v3.56 — handled as `failed`)

### 2.5 `xcode_scheme_changed`
- **Trigger:** AppleScript active scheme `.name` differs from prior tick (scheme switch with same or different workspace doc).
- **Mechanism:** `XcodeBuildLifecycleStateMachine`.
- **Payload:**
  - `event_kind` = `xcode_scheme_changed`
  - `scheme` — new scheme name
  - `scheme_prev` — prior scheme name (optional, omitted on first observation)
  - `project` — workspace document name

### 2.6 `xcode_run_destination_changed`
- **Trigger:** AppleScript `active run destination.name` raw value differs from prior tick. Bucket transition: emit only when **bucketed** value differs (Mac → iPhone Simulator → physical device). Same-bucket transitions (e.g. iPhone 15 Sim → iPhone 16 Sim) suppressed to control noise.
- **Mechanism:** `XcodeBuildLifecycleStateMachine`.
- **Payload:**
  - `event_kind` = `xcode_run_destination_changed`
  - `run_destination_bucket` — new bucket
  - `run_destination_bucket_prev` — prior bucket (optional)

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│ AGENT (LeafAgent target, 60s tick scheduler)                     │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │ AppleScriptDispatchLogic (existing, untouched)          │     │
│  │  → for each bundle in registry:                         │     │
│  │      if enabled + shouldProbe + isInstalled:            │     │
│  │        run tickScript → parse → adapter.observe(...)    │     │
│  └─────────────────────────────────────────────────────────┘     │
│            │                                                     │
│            ▼ (com.apple.dt.Xcode)                                │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │ ProdXcodeAdapter (LeafCorePrivate/Prod/Collectors/Apple)│     │
│  │  - tickScript: extended to fetch run destination        │     │
│  │  - parse: builds XcodeObservation (+2 new fields)       │     │
│  │  - observe:                                             │     │
│  │      1. XcodeStateMachine (S2) → 0..2 RawEvents         │     │
│  │      2. XcodeBuildLifecycleStateMachine → 0..4 events   │     │
│  └─────────────────────────────────────────────────────────┘     │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │ DerivedDataFSEventsWatcher (LeafCorePrivate/Prod/...)   │     │
│  │  - actor; lifecycle owned by Agent.start/stop           │     │
│  │  - FSEventStream on ~/Library/Developer/Xcode/...       │     │
│  │  - cold-start: walk → cursor = max(mtime), persist      │     │
│  │  - on dir-created in Logs/Test/*.xcresult:              │     │
│  │      XcodeTestRunStateMachine.observeStarted(...)       │     │
│  │  - on Info.plist write (debounced 1s):                  │     │
│  │      XcresultStructuredSummaryParser → observe(...)     │     │
│  └─────────────────────────────────────────────────────────┘     │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │ XcresultStructuredSummaryParser                         │     │
│  │  - Process()/usr/bin/xcrun xcresulttool ... --legacy    │     │
│  │  - 5s timeout, walkback forbidden fields, return struct │     │
│  └─────────────────────────────────────────────────────────┘     │
│                                                                  │
│  ▼  RawEvents → EventsStore.append (existing pipeline)           │
└──────────────────────────────────────────────────────────────────┘
```

Three independent emission paths: existing S2 (untouched), new lifecycle (AppleScript tick), new FSEvents (real-time). Each path produces typed `RawEvent`s that flow through the existing Agent → EventsStore pipeline unchanged.

---

## 4. Component contracts

### 4.1 `XcodeBuildLifecycleStateMachine` (public, `LeafCore/OS/`)

```swift
public struct XcodeBuildLifecycleStateMachine: Sendable, Hashable {
    public init()

    public mutating func observe(
        _ obs: XcodeObservation,
        nowMs: Int64
    ) -> [RawEvent]
}
```

- **Pure transition detector.** No IO. Hash + Equatable for snapshot testing.
- **State carried across ticks:** `prev: XcodeObservation?`, `lastBuildStartedMs: Int64?` (for `duration_ms` derivation on finish), `prev: schemeName, runDestinationBucket`.
- **Emission order per tick:** scheme_changed → run_destination_changed → build_started → build_finished. Max 4 events per tick (4 transitions all firing simultaneously is extremely rare but allowed).
- **First-observation policy:** the first observation in a session **does NOT emit** any of the 4 new event_kinds. No prior tick exists to diff against; we cannot know whether the observed `running` status started this tick or before Agent boot. Emit nothing — the next status transition (running→succeeded etc.) will catch up the build_finished event. See §6.1 for the cold-start contract.

### 4.2 `XcodeTestRunStateMachine` (public, `LeafCore/OS/`)

```swift
public struct XcodeTestRunStateMachine: Sendable, Hashable {
    public init()

    public mutating func observeStarted(
        bundlePath: String,
        scheme: String?,
        runDestinationBucket: String,
        nowMs: Int64
    ) -> [RawEvent]

    public mutating func observeFinished(
        bundlePath: String,
        summary: XcresultTestSummary,
        nowMs: Int64
    ) -> [RawEvent]
}
```

- **De-duplication:** carries a set of `seenBundlePaths` keyed by absolute xcresult path. `observeStarted` emits at most once per bundle path; `observeFinished` likewise. Eviction policy: LRU cap of 256 paths (xcresult bundles per project rarely exceed 8/day, 256 covers 32 days × 8 projects).
- **Pairing:** `observeFinished` for a bundle without a prior `observeStarted` is still emitted (cold-start case: bundle appeared while watcher was offline). It emits `test_run_finished` without a prior `test_run_started`.

### 4.3 `XcresultStructuredSummaryParser` (moat, `LeafCorePrivate/Prod/`)

```swift
public struct XcresultBuildSummary: Sendable, Equatable {
    public let errorCount: Int
    public let warningCount: Int
    public let analyzerWarningCount: Int
    public let targetNames: Set<String>       // walkback applied — no raw error messages
    public let destinationBucket: String      // bucketed
    public let durationMs: Int64?
}

public struct XcresultTestSummary: Sendable, Equatable {
    public let passedCount: Int
    public let failedCount: Int
    public let skippedCount: Int
    public let expectedFailureCount: Int
    public let totalCount: Int
    public let durationMs: Int64?
    public let scheme: String?
    public let destinationBucket: String
}

public enum XcresultParseError: Error {
    case toolMissing                    // xcrun/xcresulttool not found
    case timeout                        // 5s exceeded
    case nonZeroExit(Int32, String)     // includes stderr (logged only, never embedded in events)
    case malformedJSON
    case legacyFlagRejected             // Xcode 27 graceful degrade signal
}

public protocol XcresultParser: Sendable {
    func parseBuildSummary(path: String) async throws -> XcresultBuildSummary
    func parseTestSummary(path: String) async throws -> XcresultTestSummary
}

public struct ProdXcresultParser: XcresultParser { ... }
```

- **Invocation:** `Process()` spawns `/usr/bin/xcrun` with args `["xcresulttool", "get", "<build|test>-results", "summary", "--legacy", "--path", path]`. stdout piped to `Data`, parsed as `JSONSerialization`.
- **Timeout:** 5 seconds (wallclock). Tracked via `DispatchSourceTimer` on a dedicated queue; on timeout, the `Process` is terminated and `.timeout` is thrown.
- **Concurrency:** the parser is `Sendable`; underlying `Process()` calls are blocking — caller awaits on a `Task.detached` to avoid blocking the FSEvents callback queue.
- **Walkback:** the parser reads `errors[].targetName` and `destination.platform` to populate `targetNames` + `destinationBucket`; **never** copies `errors[].message`, `errors[].sourceURL`, `destination.deviceName`, `destination.modelName`, individual `test.identifier` strings. Walkback enforced as positional accessors with a fixed allowlist — see §8.

### 4.4 `DerivedDataFSEventsWatcher` (moat, `LeafCorePrivate/Prod/`)

```swift
public protocol DerivedDataWatcher: Sendable {
    func start() async
    func stop() async
}

public actor ProdDerivedDataWatcher: DerivedDataWatcher {
    init(
        rootPath: String,                            // ~/Library/Developer/Xcode/DerivedData
        cursor: any DerivedDataCursor,               // persistence interface
        parser: any XcresultParser,
        sink: any RawEventSink,                      // existing Agent sink
        nowMs: @Sendable () -> Int64,                // injectable clock for tests
        featureGate: @Sendable () -> Bool            // Settings → System Observers toggle
    )

    // XcodeTestRunStateMachine is owned BY the actor as an actor-isolated
    // stored property (mutated only inside actor methods) — not passed in.
}
```

- **FSEventStream config:** `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseExtendedData | kFSEventStreamCreateFlagWatchRoot`, `sinceWhen = kFSEventStreamEventIdSinceNow` (NEVER replay historical events — cursor handles backfill).
- **Cold start:** on `start()`, walk all `<rootPath>/*/Logs/{Test,Launch}/*.xcresult` paths once, find max mtime per DerivedData-hash, persist cursor. **Do NOT emit** any test_run events for pre-existing bundles. If cursor is fresh-zero (first run ever), still suppress — accept that we miss historical test runs (acceptable: no retroactive emission per ADR-010 spirit).
- **Stream callback:** filter event paths against regex `.*/Logs/(Test|Launch)/[A-F0-9-]+\.xcresult$` (dir-created → started) and `.*/Logs/(Test|Launch)/[A-F0-9-]+\.xcresult/Info\.plist$` (modified → finished, after 1s stable-write debounce).
- **Stability detection:** Info.plist may be written incrementally. The watcher waits 1s after the last mutation event on the file before invoking the parser. Max wait: 30s (then attempt parse anyway; if `malformedJSON` is thrown, drop the event).
- **Feature gate:** if `featureGate()` returns false (Settings → System Observers "DerivedData watcher" toggle OFF), `start()` becomes a no-op. Toggle change requires Agent restart (mirror Track-4 S3 pattern).

### 4.5 `DerivedDataCursor` (public, `LeafCore/Storage/`)

```swift
public protocol DerivedDataCursor: Sendable {
    func lastSeenMtimeMs(forHash hash: String) async -> Int64?
    func setLastSeenMtimeMs(_ ms: Int64, forHash hash: String) async
    func allKnownHashes() async -> [String]
}

public struct ProviderSnapshotsDerivedDataCursor: DerivedDataCursor { ... }
```

- **Persistence:** existing `provider_snapshots` table (M015), single row with `provider="xcode_derived_data"` + `snapshot_kind="cursor"`. JSON shape: `{"hashes": {"Leaf-dqqvphprbvvfkxabaugkymigacwk": 1778932868319, ...}}`. Atomic single-row update on every cursor advance. No new table; no new migration.
- **Hash extraction:** `<hash>` is the 28-char Xcode-mint hash in the DerivedData path (`Leaf-dqqvphprbvvfkxabaugkymigacwk` → `dqqvphprbvvfkxabaugkymigacwk`). The full directory name (including `<ProjectName>-` prefix) is recorded as the key suffix to preserve human readability in introspection.

### 4.6 `ProdXcodeAdapter` extension (existing, moat)

**Existing fields preserved:** `activeDocPath`, `projectName`, `schemeName`, `buildState`.
**New fields:** `runDestinationName: String?`, `runDestinationBucket: String` (derived in-adapter from name).
**Bucketing function** (also exposed publicly for state-machine reuse):

```swift
public enum RunDestinationBucket: String, Sendable {
    case macos
    case iosSimulator = "ios_simulator"
    case iosDevice    = "ios_device"
    case tvSimulator  = "tv_simulator"
    case tvDevice     = "tv_device"
    case watchSimulator = "watch_simulator"
    case watchDevice  = "watch_device"
    case visionSimulator = "vision_simulator"
    case visionDevice = "vision_device"
    case unknown

    public static func bucket(rawName: String?) -> RunDestinationBucket { ... }
}
```

Heuristic: scan rawName for `"My Mac"` / `"Simulator"` / `"iPhone"` / `"iPad"` / `"Apple Watch"` / `"Apple TV"` / `"Vision"` substrings + `"(Simulator)"` suffix presence. Raw `rawName` never stored in events. Heuristic table lives in the same `RunDestinationBucket.swift` file as a `static let heuristicTable: [(needle: String, bucket: RunDestinationBucket)]` ordered by specificity (Simulator suffixes first, then device families, fallback unknown).

---

## 5. Data flow per event_kind

| event_kind | Source | Trigger | Latency | Cursor | Walkback fields |
|---|---|---|---|---|---|
| `xcode_active_doc_changed` | AppleScript tick | doc/project/scheme tuple diff | ≤60s | n/a (S2) | n/a (S2) |
| `xcode_build_state_changed` | AppleScript tick | status enum flip | ≤60s | n/a (S2) | n/a (S2) |
| `xcode_build_started` | AppleScript tick | status → running | ≤60s | first-tick suppression via lifecycle-cursor | none (no enrichment) |
| `xcode_build_finished` | AppleScript tick + opt xcresult | status → terminal | ≤60s + ≤5s parse | sibling xcresult by mtime ±5s | error message, sourceURL, deviceName |
| `xcode_test_run_started` | FSEvents | dir-created on xcresult | <1s | per-hash mtime cursor | scheme metadata if not in path |
| `xcode_test_run_finished` | FSEvents + xcresult | Info.plist stable write | <1s + ≤5s parse + 1s debounce | per-hash mtime cursor | test names, error messages, deviceName |
| `xcode_scheme_changed` | AppleScript tick | scheme name diff | ≤60s | suppressed on first tick | none |
| `xcode_run_destination_changed` | AppleScript tick | bucketed value diff | ≤60s | suppressed on first tick | raw deviceName never stored |

---

## 6. Cold-start handling

Two independent cold-start paths, both must suppress historical emission.

### 6.1 AppleScript-driven (build/scheme/run-destination)

On Agent boot, `XcodeBuildLifecycleStateMachine.prev` starts as `nil`. First observation sets `prev` but emits **none** of the 4 new event_kinds — no prior tick to diff against. `build_state_changed` from S2 still emits the running state per S2's first-observation semantic (S2 contract unchanged). The very next observed status transition (e.g. `running → succeeded` on the second tick) emits `build_finished` normally, with `duration_ms` derived from when the machine first saw `running` (best-effort; documented imprecise on cold start).

### 6.2 FSEvents-driven (test_run_*)

On `ProdDerivedDataWatcher.start()`:
1. Walk all `<root>/*/Logs/{Test,Launch}/` directories, find max-mtime xcresult bundle per DerivedData-hash.
2. For each hash, write `cursor.lastSeenMtimeMs(hash) = max(mtime, existing_cursor)`.
3. Open the FSEventStream with `sinceWhen = kFSEventStreamEventIdSinceNow`.
4. In the callback, an event is emitted only if the bundle's mtime > cursor for that hash.

Edge case: when a new project is added (new DerivedData hash appears), the watcher receives `kFSEventStreamEventFlagItemIsDir | ItemCreated` on the project dir. The actor lazily creates a cursor for that hash (set to `now`) and starts emitting from that point forward. Pre-existing xcresults under a brand-new hash are never possible (Xcode mints the hash on first build for that workspace, so any xcresult appears AFTER the hash dir).

---

## 7. AppleScript script extension

Current S2 script (paraphrased):
```applescript
tell application "Xcode"
  if not running then error
  set ws to first item of (every workspace document whose loaded is true)
  set docPath to path of ws
  set projName to name of ws
  set schName to name of (active scheme of ws)
  set st to status of (last scheme action result of ws)
  return {docPath, projName, schName, st}
end tell
```

P2 extension (add 1 field; same single round-trip):
```applescript
tell application "Xcode"
  ...
  set rdName to "(none)"
  try
    set rdName to name of (active run destination of ws)
  end try
  return {docPath, projName, schName, st, rdName}
end tell
```

`try ... end try` is critical — `active run destination` returns `missing value` when no destination is selected, which raises an AppleEvent error if read directly. Live-probed on author's Mac.

Total script length increases by ~80 chars. 1s timeout unchanged. `ProdXcodeAdapter.parse(_:for:)` extended to read the 5th list element and apply `RunDestinationBucket.bucket(rawName:)`. No new TCC prompt — same Apple Events permission as existing.

---

## 8. Privacy walkback discipline

Per contract §7 P2 + ADR-010.

### 8.1 Walkback table (per event_kind, per forbidden field)

| Field | Source path | Walkback method |
|---|---|---|
| `errors[].message` (build) | xcresulttool JSON | NEVER read in parser; positional access skips this key |
| `errors[].sourceURL` | xcresulttool JSON | NEVER read |
| `destination.deviceName` | xcresulttool JSON | NEVER read; bucketed from `destination.platform` + heuristic on `destination.simulator` flag |
| `destination.modelName` | xcresulttool JSON | NEVER read |
| `destination.osBuildNumber` | xcresulttool JSON | NEVER read |
| `tests[].identifier` (test method names) | xcresulttool test-results JSON | NEVER read; only aggregate counts |
| `tests[].failureMessage` | xcresulttool test-results JSON | NEVER read |
| `activityLog.subtitle` (build log content) | xcresulttool | NEVER read |
| `actions[].buildResult.warningSummaries[].message` | xcresulttool | NEVER read |
| Active run destination raw name | AppleScript `name of active run destination` | READ to compute bucket, **dropped before sink** |
| AppleScript script source on stderr in error path | Process stderr | LOG only via Logger, NEVER embed in RawEvent |

### 8.2 Sentinel test fence

A dedicated test in `LeafCorePrivateTests`:

```swift
@Test func sentinelLeakWalkback_AllXcodeKinds() async throws {
    // Inject LEAKED_SENTINEL_XCODE_P2 into every forbidden field
    // in a fixture xcresult JSON; assert no event payload contains it.
    let sentinel = "LEAKED_SENTINEL_XCODE_P2"
    // ... 6 fixture variants × 6 new event_kinds × 5 forbidden fields
}
```

Public-side fence in `RelayBodyLeakageTests`:

```swift
@Test func testEventBodyDoesNotLeakIntoPresenceState_XcodeP2() async throws {
    // Feed RawEvents with sentinel-injected payloads through the full
    // presence-state writer pipeline; assert the resulting presence_state
    // JSON contains no sentinel.
}
```

### 8.3 Walkback verification at parser layer

`XcresultStructuredSummaryParser` uses **positional accessors with explicit allowlist** rather than `Codable` whole-struct decode. Decoding the full struct via Codable would silently capture forbidden fields into Swift Strings that then leak via `String(describing:)` or debug logs. Allowlist:

```swift
// Allowed root keys:
private let allowedBuildRootKeys: Set<String> = [
    "errorCount", "warningCount", "analyzerWarningCount",
    "startTime", "endTime", "errors", "destination"
]
private let allowedErrorKeys: Set<String> = ["targetName"]  // ONLY targetName from errors[]
private let allowedDestKeys: Set<String> = ["platform", "simulator"]  // for bucketing
```

The parser walks the JSON tree, copying only keys in the allowlists. Any other field is silently dropped (not logged with key name — key names themselves could be sensitive in future Apple schemas).

---

## 9. Schema + registry deltas

### 9.1 SQLCipher migrations

**None.** M025 reservation explicitly released for P2 — future phases may use it. Comment added to `LeafCore/DB/Migrations.swift` documenting the release.

### 9.2 ShareEventTypeKey registry append (default OFF)

6 new entries at the bottom of `ShareEventTypeRegistry.swift`. Last-line fence updated.

```swift
case xcodeBuildStarted          // "xcode_build_started"
case xcodeBuildFinished         // "xcode_build_finished"
case xcodeTestRunStarted        // "xcode_test_run_started"
case xcodeTestRunFinished       // "xcode_test_run_finished"
case xcodeSchemeChanged         // "xcode_scheme_changed"
case xcodeRunDestinationChanged // "xcode_run_destination_changed"
```

Registry baseline on `main` is 152. After P2: **158** on this branch. Collective Track-6 integration count not P2's concern (resolved at integration merge).

### 9.3 ShareEventTypeDefaults

All 6 new keys set `defaultEnabled: false`.

### 9.4 ActivityFeedMapper

`ActivityFeedMapper.mapLocalApps` switch extended with 6 new cases:

| event_kind | primary | secondary |
|---|---|---|
| `xcode_build_started` | `"Xcode: build started"` | scheme + run_destination_bucket (e.g. "Leaf · macos") |
| `xcode_build_finished` | `"Xcode: build " + status` | scheme + error_count if present (e.g. "Leaf · 4 errors") |
| `xcode_test_run_started` | `"Xcode: tests started"` | scheme |
| `xcode_test_run_finished` | `"Xcode: tests " + status` | "N passed, M failed" |
| `xcode_scheme_changed` | `"Xcode: scheme " + scheme` | project |
| `xcode_run_destination_changed` | `"Xcode: target " + run_destination_bucket` | (none) |

`EventKindIcon` (Track-4 S4 helper) extended with 6 new SF Symbol mappings:
- `xcode_build_started` → `hammer`
- `xcode_build_finished` → `hammer.fill` (status=succeeded green-tinted in view layer)
- `xcode_test_run_started` → `checkmark.diamond`
- `xcode_test_run_finished` → `checkmark.diamond.fill`
- `xcode_scheme_changed` → `square.stack.3d.up`
- `xcode_run_destination_changed` → `display`

### 9.5 DispatchCoverageTests #16

New parity fence enumerating all 8 `xcode_*` event_kinds (2 S2 + 6 P2) and asserting each appears in:
- `ShareEventTypeRegistry.allKeys`
- `ShareEventTypeDefaults` (with `defaultEnabled: false`)
- `ActivityFeedMapper.mapLocalApps` switch (compile-time exhaustiveness validated by switch over enum + runtime check via fixture)
- `EventKindIcon` SF Symbol map

---

## 10. UI surface

### 10.1 Settings → Local Apps → Xcode row

Existing master toggle gates the entire adapter (no change). Below it, a new sub-section `Builds & tests` with 6 sub-toggles:
- Build started
- Build finished
- Test run started
- Test run finished
- Scheme changed
- Run destination changed

Each sub-toggle drives a `ShareEventTypeKey` entry. All default OFF. Sub-toggles are inert when master is OFF (visually disabled).

### 10.2 Settings → System Observers

New row: **DerivedData watcher**. Default OFF. Description copy:
> "Detects when Xcode finishes a test run by watching the DerivedData folder. Required to record test pass/fail counts and build error counts. Apple Events permission is still gated separately under Local Apps → Xcode."

Toggle drives `DerivedDataWatcherEnabled` in `LocalAppsStore` (new key). Watcher reads this gate in `start()`.

### 10.3 Privacy dashboard reverse view

Adds 6 rows to the "What you're sharing" list when the corresponding ShareEventTypeKey is ON. Re-renders via existing Track-2 D4 wiring; no new code.

---

## 11. Test strategy

| Test target | Scope |
|---|---|
| `XcodeBuildLifecycleStateMachineTests` | All 4 transitions, first-observation suppression, duration_ms math, bucketed-only run-destination diff, max 4 events per tick combo. ~12 cases. |
| `XcodeTestRunStateMachineTests` | observeStarted/observeFinished de-dup, LRU eviction at 256 paths, finished-without-started cold-path. ~6 cases. |
| `RunDestinationBucketTests` | Heuristic table — "My Mac", "iPhone 15 (Simulator)", "iPhone 16 Pro", "Apple Watch Ultra 2 (49mm)", "Apple TV 4K (3rd generation)", "Vision Pro (Simulator)", nil, "(none)", unknown string. ~12 cases. |
| `XcresultStructuredSummaryParserTests` | Fixture JSON parsing — happy path build, happy path test, build with 4 errors (target name aggregation), test with mixed pass/fail/skip/expected-failure, timeout error path (mock `Process`), legacy-flag-rejected path. Walkback assertion: feed fixture JSON containing `LEAKED_SENTINEL_XCODE_P2` in every forbidden field; assert returned struct contains no sentinel. ~10 cases. |
| `ProdDerivedDataWatcherTests` | Cold-start cursor walkback (synthesize fixture filesystem via temp dir, populate with pre-existing xcresult bundles, assert no events emitted on start). New bundle appearance → started event. Info.plist write → debounced finished event. Feature-gate OFF → no-op start. ~6 cases. |
| `XcodeAppleScriptParseTests` | Parse extended NSAppleEventDescriptor with 5-element list; verify run_destination_name extraction + bucketing. Verify missing-value handling. ~4 cases. |
| `RelayBodyLeakageTests.testEventBodyDoesNotLeakIntoPresenceState_XcodeP2` | Sentinel walkback fence (public side). 1 case enumerating all 6 new event_kinds. |
| `DispatchCoverageTests.testDispatchParity_XcodeP2_AllKinds` | New parity fence (#16) — all 8 xcode_* kinds in registry/defaults/mapper/icon. 1 case. |
| `ActivityFeedMapperTests` | 6 new switch cases — primary/secondary text generation. ~6 cases. |

**Total new tests:** ~58. Per-step decomposition in writing-plans stage.

**Smoke gate (manual, post-impl):** see §14.

---

## 12. File layout

### 12.1 New files (public, `Packages/LeafCore/Sources/LeafCore/`)

- `OS/XcodeBuildLifecycleStateMachine.swift` (~150 LOC)
- `OS/XcodeTestRunStateMachine.swift` (~100 LOC)
- `OS/RunDestinationBucket.swift` (enum + heuristic, ~80 LOC)
- `OS/XcresultBuildSummary.swift` (struct definitions, ~40 LOC)
- `OS/XcresultTestSummary.swift` (struct definitions, ~40 LOC)
- `OS/XcresultParser.swift` (protocol declaration, ~20 LOC)
- `OS/DerivedDataWatcher.swift` (protocol declaration, ~20 LOC)
- `DB/DerivedDataCursor.swift` (protocol + `ProviderSnapshotsDerivedDataCursor` impl using existing `ProviderSnapshotsStore`, ~80 LOC)
- `Insights/EventKindIcon+XcodeP2.swift` (icon mapping extension, ~30 LOC)
- Extended: `Insights/ActivityFeedMapper.swift` (6 new switch cases)
- Extended: `Share/ShareEventTypeRegistry.swift` (6 new cases)
- Extended: `Share/ShareEventTypeRegistry.swift` (the same file holds both enum cases AND the defaults array in this codebase — append 6 cases + 6 default entries in one PR)

### 12.2 New files (moat, `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Collectors/Apple/`)

- `ProdXcresultParser.swift` (~200 LOC — Process invocation + JSON allowlist walker)
- `ProdDerivedDataWatcher.swift` (~250 LOC — actor + FSEventStream + cold-start walk)
- Extended: `ProdXcodeAdapter.swift` — tickScript extension + parse() extension + observe() integration

### 12.3 Test files

- `Packages/LeafCore/Tests/LeafCoreTests/XcodeBuildLifecycleStateMachineTests.swift`
- `Packages/LeafCore/Tests/LeafCoreTests/XcodeTestRunStateMachineTests.swift`
- `Packages/LeafCore/Tests/LeafCoreTests/RunDestinationBucketTests.swift`
- `Packages/LeafCore/Tests/LeafCoreTests/ActivityFeedMapperTests.swift` (extend existing)
- `Packages/LeafCorePrivate/Tests/LeafCorePrivateTests/XcresultStructuredSummaryParserTests.swift`
- `Packages/LeafCorePrivate/Tests/LeafCorePrivateTests/ProdDerivedDataWatcherTests.swift`
- `Packages/LeafCorePrivate/Tests/LeafCorePrivateTests/XcodeAppleScriptParseTests.swift` (extend existing)
- `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` (+1 case)
- `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift` (+1 case, #16)

### 12.4 Agent wiring

`LeafAgent/Agent.swift` — new init paths:
1. Construct `ProdXcresultParser`, `CollectorOffsetsDerivedDataCursor`, `ProdDerivedDataWatcher` with `featureGate = { LocalAppsStore.derivedDataWatcherEnabled() }`.
2. On `start()`, call `watcher.start()` if gate is ON.
3. On `stop()`, call `watcher.stop()`.

`LeafCorePrivate` exports remain through public protocol initializers (`ProdDerivedDataWatcher.init(...)` is public).

---

## 13. Migration discipline

- `M025` reservation **released**. Comment in `LeafCore/DB/Migrations.swift`:
  > `// M025 — reserved for Track 6 P2 (Xcode Deep). Released 2026-05-16 — P2 ships without new tables. Available for next phase.`

- `provider_snapshots` table (M015) reused for cursor — single row `provider="xcode_derived_data"`, `snapshot_kind="cursor"`, JSON value `{"hashes": {hash: mtimeMs, ...}}`. No schema change. No new migration.

---

## 14. Acceptance smoke gate (manual, post-impl)

Per contract §10 + §2.6.

**A. Build lifecycle (master ON, sub-toggles ON):**
1. Open Xcode, select scheme Leaf. Verify no immediate events (first-tick suppression).
2. Press Cmd+B. Within 60s: 1 `xcode_build_started` row in DB. After build completes: 1 `xcode_build_finished` row with `status=succeeded`, `duration_ms` reasonable, `error_count=0`.
3. Break the build (introduce syntax error), Cmd+B. After completion: 1 more `build_finished`, `status=failed`, `error_count>0`, `target_name_top` set if single target.

**B. Test lifecycle (master ON, sub-toggles ON, System Observers DerivedData watcher ON):**
1. Run Cmd+U. Within 1s: `xcode_test_run_started` row (FSEvents real-time). After tests complete: 1 `xcode_test_run_finished` with `passed_count`, `failed_count`, `total_count` matching Xcode's report.
2. Cancel mid-run (Cmd+.). Verify `test_run_finished` not emitted (xcresult is incomplete; parser fails on malformedJSON → dropped).

**C. Scheme + run destination:**
1. Switch scheme from Leaf to LeafAgent. Within 60s: 1 `xcode_scheme_changed`, `scheme_prev=Leaf`, `scheme=LeafAgent`.
2. Switch run destination from My Mac to iPhone 16 Simulator. Within 60s: 1 `xcode_run_destination_changed`, `run_destination_bucket=ios_simulator`, `run_destination_bucket_prev=macos`.
3. Switch from iPhone 16 Sim to iPhone 15 Sim. **No event** (same bucket).

**D. Cold start:**
1. Stop Agent. Run Cmd+U externally (xcresult appears while Agent is down).
2. Start Agent. Verify no `test_run_finished` emitted for that historical bundle (cursor suppression).
3. Run a fresh Cmd+U. Verify the new bundle is captured.

**E. Privacy walkback grep:**
```bash
sqlite3 events.sqlite "SELECT payload_json FROM events WHERE payload_json LIKE '%xcode_%' AND (payload_json LIKE '%LEAKED%' OR payload_json LIKE '%My Mac%' OR payload_json LIKE '%MacBook%' OR payload_json LIKE '%Cannot find%' OR payload_json LIKE '%Compiler Error%')"
```
Expected: zero rows.

**F. System Observers OFF:** toggle watcher OFF, restart Agent. Cmd+U → no `test_run_*` events. AppleScript-driven build/scheme/run-destination events still fire (independent gate).

**G. ShareEventTypeKey default-OFF:** fresh install (delete UserDefaults `tech.gundem.leaf` + DB). All 6 new event_kinds default OFF — verify by inspecting Settings UI; verify no events emitted until each toggled ON.

---

## 15. Out of scope (this phase)

- xcactivitylog binary SLF parsing (confirmed skip per Stage 0 research).
- Per-scheme allow-list (confirmed skip per Stage 0 research).
- `xcode_target_changed`, `xcode_configuration_changed`, `xcode_clean_performed` (Marginal value per research §5).
- Breakpoint / debugger state capture (permanently forbidden — ADR-010).
- xcresulttool new-command-surface dual-path parser (Xcode 27 risk; carry-over).
- Derived Insights (Phase 4.9): build velocity stats, test flakiness rate, mean build time. Substrate ready; consumers come later.

---

## 16. Known caveats / carry-overs

1. **xcresulttool `--legacy` deprecation.** Xcode 26+ marks the commands "legacy"; Xcode 27 may remove. Carry-over: in `current-state.md` post-ship, add "Audit xcresulttool migration when Xcode 27 lands."
2. **FSEvents historical-event replay.** We pin `sinceWhen = kFSEventStreamEventIdSinceNow`. If Apple changes default behaviour in macOS 27, our cursor still suppresses — defence-in-depth.
3. **Pure-Cmd+B build error count.** Plain Cmd+B (no Run) produces only xcactivitylog, not xcresult. `build_finished` for these endpoints fires without enrichment (no error_count). Accept gap; document in carry-overs.
4. **DerivedData symlinks.** If user has set custom DerivedData location via `defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation`, our hard-coded `~/Library/Developer/Xcode/DerivedData/` misses it. Defer to v1.1; for v1 we document the assumption in Settings → System Observers row hover text.
5. **Multiple Xcode versions installed.** AppleScript targets `com.apple.dt.Xcode` (whichever Xcode is registered as default). Xcode-beta has separate bundle ID `com.apple.dt.Xcode-beta` — not captured. Defer to v1.1.

---

## 17. Acceptance criteria (writing-plans input)

- [ ] 6 new event_kinds emitted with documented payload schemas.
- [ ] 0 new SQLCipher tables (M025 released back).
- [ ] ShareEventTypeKey registry: 152 → 158 on this branch, all 6 new entries `defaultEnabled = false`.
- [ ] `XcodeBuildLifecycleStateMachine` + `XcodeTestRunStateMachine` pure (Sendable, Hashable, no IO).
- [ ] `XcresultStructuredSummaryParser` walkback verified by sentinel fence (`LEAKED_SENTINEL_XCODE_P2`).
- [ ] `ProdDerivedDataWatcher` cold-start cursor: zero historical emissions on first-run integration test.
- [ ] `DispatchCoverageTests` #16 fence covers all 8 `xcode_*` event_kinds.
- [ ] `RelayBodyLeakageTests.testEventBodyDoesNotLeakIntoPresenceState_XcodeP2` green.
- [ ] All 5 xcodebuild schemes (Leaf, LeafAgent, LeafMCP, LeafCore, LeafCorePrivate) build with zero warnings.
- [ ] Net SPM test count: +58 (target). Final count locked in implementation.
- [ ] Smoke gate sections A–G pass on author's Mac.

---

## 18. Decision log

| Date | Decision | Source |
|---|---|---|
| 2026-05-16 | Skip xcactivitylog binary parsing | Stage 0 Q1, user confirmed |
| 2026-05-16 | No per-scheme allow-list | Stage 0 Q2, user confirmed |
| 2026-05-16 | Pin xcresulttool `--legacy` | Stage 0 Q3, user confirmed |
| 2026-05-16 | Keep `build_state_changed` emission alongside `build_started/finished` | Stage 0 Q4, user confirmed |
| 2026-05-16 | No FDA defensive seam | Stage 0 Q5, auto-decided (live-tested no prompt) |
| 2026-05-16 | Approach A: FSEvents + state-machine split | Stage 2 brainstorm |
| 2026-05-16 | M025 reservation released | Schema needs are zero — only ShareEventTypeKey + state machines + cursor in existing M013 |
| 2026-05-16 | Bucketed-only emission for `run_destination_changed` | Suppresses noise on iPhone-Simulator-variant churn while keeping Mac↔iOS↔tvOS↔visionOS↔watchOS transitions |
| 2026-05-16 | First-tick suppression for build_started + scheme_changed + run_destination_changed | Avoids replaying state on Agent boot; cold-start hygiene |
| 2026-05-16 | xcresulttool 5s timeout via Process + DispatchSourceTimer | Avoids blocking FSEvents callback; tight bound on parse runtime |
