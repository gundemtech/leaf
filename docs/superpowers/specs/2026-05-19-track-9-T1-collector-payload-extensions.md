# Track-9 T1 — Collector payload extensions + AX line capture + recentLastCommit deriver

**Status:** APPROVED (Stage 3, awaiting user spec-review gate).
**Track-9 master design:** [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md).
**Branch:** `feature/track-9-substrate` (off `feature/phase-8-1-substrate` `e659b9e5`, opened Stage 1 this session).
**Ship classification:** Substrate-only, silent — UI без изменений, кроме 2 новых toggle rows в Settings → System Observers.

---

## 1. Scope

**In scope:**
1. AX `AXSelectedTextRange` + `AXLineForIndex` integration в Track-6 P2 Xcode collector → `xcode_active_doc_changed.line: Int?` Optional payload field.
2. `VSCodeWorkspaceWatcher.buildEvent` emit'ит `workspace_root: String` (tilde-prefixed `~/...` sanitized path) в `vscode_workspace_opened`.
3. `JetBrainsRecentProjectsWatcher` XML parser extract'ит `key` attribute (`$USER_HOME$/...` → `~/...`) → emit'ит `workspace_root` в `jetbrains_recent_project_observed`.
4. `DerivedInsights.recentLastCommit(maxAgeMs: Int64) throws -> RecentCommitSnapshot?` substrate helper + `RecentCommitSnapshot { subject: String, branch: String?, atMs: Int64 }` тип + `ProdInsights+LastCommit.swift` SQL impl + `StubInsights` default `nil`.
5. 4 sentinel-injection regression tests (3 per-field + 1 integration sweep) в `RelayBodyLeakageTests`.
6. Walkback contract update в `VSCodeWorkspaceWatcher.swift` documentation block — sanctioned tilde-prefixed paths.
7. Settings → System Observers: 2 новых toggle rows (`axLineCaptureEnabled`, `ideWorkspacePathTrackingEnabled`), default ON.
8. `LocalAppsStore` +2 boolean properties + UserDefaults keys.

**Hard exclusion (out of T1):**
- `vscode_active_doc_changed.workspace_root` payload field — **DEVIATION от master spec §5.1**, см. §1.1 ниже.
- T5 YOU·NOW branch deriver impl (`currentTaskIdentity()` per-IDE dispatch + git HEAD walk).
- T7 `WhereStoppedSnapshot.{anchorFilePath, anchorLine, recentLastCommit}` field additions + `ProdWhereStoppedDeriver` extension consuming `recentLastCommit`.
- M028 SQLCipher migration (`where_stopped_log` add columns) — T7 scope.
- VSCode/JetBrains AX line capture (Electron / JBR AX variable — won't-list, carry post-Track-9).
- UI surface changes beyond Settings toggles (HomeView etc).
- AI narrative / Activity tab / WHERE STOPPED UI.

### 1.1 Deviation from Track-9 master spec §5.1

Master spec line 248 declares:
> `vscode_active_doc_changed.workspace_root: String` (T1)

T1 **does not add** `workspace_root` to `vscode_active_doc_changed`. Reason: `vscode_active_doc_changed` is emitted by the title-parser layer (`VSCodeFamilyDispatcher` consumes a window title received from `AttentionEmissionPlanner` AX read). The title parser physically has no access to the absolute workspace path — the title is already sanitized by VSCode itself before AX exposes it.

Adding `workspace_root` to this event requires either:
- In-memory `workspaceName → workspace_root` cache populated by `vscode_workspace_opened` events, consumed by title parser. Cross-process state, cold-start gap, cache eviction concerns.
- Direct file-system scan for `workspace.json` matching the parsed `workspaceName`. Expensive, brittle, requires walking `~/Library/Application Support/Code/User/workspaceStorage/<hash>/`.

**T1 emits `workspace_root` only on FSEvents-driven events** (`vscode_workspace_opened` + `jetbrains_recent_project_observed`), which natively have the absolute path in their parsing surface.

**T5 deriver** (separate phase) consumes via DB-join — looks up the most-recent `vscode_workspace_opened` event whose payload matches the given workspace_name and reads its `workspace_root` field. Single indexed lookup, cheap, no cross-process state. Cold-start case: if no `workspace_opened` event yet (Agent just started + workspace was opened pre-Agent-launch), deriver gracefully falls back to no branch info, same as current behavior pre-T1.

Master spec to be amended in T10 wrap if the deviation is accepted; T1 spec is the authoritative implementation contract.

---

## 2. Decisions taken (Stage 2 brainstorm output)

| # | Question | Decision | Rationale |
|---|---|---|---|
| D-1 | VSCode/JetBrains `workspace_root` shape | **Path A — tilde-prefixed `~/...` sanitized** | Buchstabe `/Users/<name>/` username never leaks. Sanitize already computed (`sanitizedPath` in `VSCodeWorkspaceWatcher.parseWorkspaceJSON`); JetBrains XML uses `$USER_HOME$` literal → trivial replacement. Deriver expands `~/` via `NSHomeDirectory()` at consumption — standard Swift idiom. |
| D-2 | Emission point for VSCode `workspace_root` | **`vscode_workspace_opened` only** (NOT `vscode_active_doc_changed`) | Title parser has no access to absolute path. T5 deriver does DB-join on `workspace_name`. Single SQL JOIN cheaper than in-memory store + cross-process IPC. |
| D-3 | AX line capture mechanism | **`AXSelectedTextRange` + `AXLineForIndex` parameterized attribute** | Returns Int line index directly. **NO document text read.** Two AX calls per 60s tick — negligible overhead. AX permission already granted (no new TCC prompt scope). |
| D-4 | `xcode_active_doc_changed.line` Optional vs always-present | **`Int?` Optional, omitted when AX text-area absent** | Mirrors existing optional fields (`doc_path`, `project`, `scheme`). When focused element isn't a text area (e.g., file navigator focused) AX returns nil — skip line field instead of emitting `-1` or zero placeholder. |
| D-5 | `RecentCommitSnapshot` file location | **`Packages/LeafCore/Sources/LeafCore/Insights/RecentCommitSnapshot.swift`** | Mirrors `TodayMetrics`, `YouNowState`, `TaskIdentity`, `TeammateMatch`, `InboxItem` precedent (derived-snapshot types for substrate consumers). `WhereStoppedSnapshot` lives in `Home/WorkState/` — that folder is work-state pulse specific, not the right home for cross-cutting commit metadata. |
| D-6 | Settings toggles default ON or OFF | **Default ON for both** | `LocalAppsStore` toggles gate LOCAL capture (not sharing). ADR-020 default-OFF discipline applies to `ShareEventTypeKey` registry (sharing), not local capture. Existing System Observers: 9/10 default ON, only Intensity default OFF due to Input Monitoring dual-prompt cost. AX already granted, IDE workspace path tracking is TCC-free. Defaulting OFF would block Track-9 YOU·NOW depth for most users without justification. |
| D-7 | ShareEventTypeKey registry delta | **0 net new entries** | Payload-only field additions to existing event_kinds. Registry baseline 195 preserved. DispatchCoverageTests #20 / #21 / etc. parity fences unaffected. |
| D-8 | Sentinel-injection test grouping | **3 per-field + 1 integration sweep** | Track-6 P6 lineage pattern — 4 per-event `test_p6_walkback_*` tests + 1 `test_p6_walkback_integrationSentinelSweep`. Per-field tests pinpoint regression; sweep guards against payload-stringification accidents. |
| D-9 | Walkback contract update in `VSCodeWorkspaceWatcher.swift:9-15` | **Amend in same commit as emission change** | Documentation block update accompanies behavior change to prevent future "but the comment says NEVER absolute path" review confusion. New text: *"MAY emit tilde-prefixed sanitized workspace path (~/...) for substrate consumers' git-HEAD walk; NEVER bare absolute path (/Users/<name>/...)"*. |
| D-10 | Settings UI placement | **Insert 2 rows below existing IDE storage sub-section, before browser bookmarks group** | `axLineCaptureEnabled` row close to existing Xcode controls (logical grouping). `ideWorkspacePathTrackingEnabled` adjacent to existing `vscodeStorageEnabled` + `jetbrainsStorageEnabled` (IDE family). Matches `SystemObserversSettingsSection.swift` existing sub-section pattern. |
| D-11 | Toggle UX hint copy | **Plain inline `explainer` Text below toggle label** | Match existing System Observer rows. No "recommended" badges (not used in codebase). |
| D-12 | TCC re-prompt for AX line capture | **None — AX trust already granted globally** | Same `AXIsProcessTrustedWithOptions` scope used by `AttentionEmissionPlanner`. Toggle OFF + ON does not re-prompt. If AX trust is revoked at OS level → line field stays nil + collector logs warning (existing pattern). |

---

## 3. Architecture

### 3.1 Component map

```
Agent process
├── ProdXcodeAdapter (moat, LeafCorePrivate)
│   └── tickScript() AppleScript → 4 items + AX query → 5-tuple
│       └── parse() → XcodeObservation { activeDocPath, projectName, schemeName, buildState, line }
│       └── feed XcodeStateMachine.observe()
│           └── makeDocChangedEvent() — payload includes "line" if observation.line != nil
│
├── VSCodeWorkspaceWatcher (LeafCore/Collectors)
│   └── parseWorkspaceJSON() → ParsedWorkspace { workspaceName, sanitizedPath }
│   └── buildEvent() — payload now includes "workspace_root" = sanitizedPath
│
└── JetBrainsRecentProjectsWatcher (LeafCore/Collectors)
    └── parseRecentProjectsXML() — extends to read `key` attribute
    └── buildEvent() — payload includes "workspace_root" = expandUserHome(keyAttr)

MenuBarApp / MCP processes (read-only)
└── DerivedInsights.recentLastCommit(maxAgeMs:) → RecentCommitSnapshot?
    └── ProdInsights+LastCommit (moat)
        └── Reads the most-recent `gh_commit_pushed` event from the action
            stream within `maxAgeMs`, ordered newest first, limit 1.
            Real query body lives in LeafCorePrivate.
        └── Decode payload_json → extract subject/branch/sha
```

### 3.2 Data flow

T1 emits — T5/T7 consume (deferred). T1 ships substrate fields; consumers in T5 (YOU·NOW branch deriver) and T7 (WHERE STOPPED 4-line layout) read them.

```
events table after T1:
  payload_json[event_kind='xcode_active_doc_changed']:
    { event_kind, doc_path, project?, scheme?, line? }   ← line ADDED (Optional)

  payload_json[event_kind='vscode_workspace_opened']:
    { event_kind, ide_bundle_id, workspace_name,
      watched_folder_id?, outside_watched_folder,
      workspace_root }                                    ← workspace_root ADDED

  payload_json[event_kind='jetbrains_recent_project_observed']:
    { event_kind, ide_bundle_id, ide_version_dir, project_name,
      activation_timestamp_ms, outside_watched_folder,
      workspace_root }                                    ← workspace_root ADDED
```

### 3.3 AX line capture mechanism

In `ProdXcodeAdapter` (LeafCorePrivate moat), after current AppleScript poll returns the 4-tuple (`path`, `project`, `scheme`, `buildState`), perform two additional AX calls if the AppleScript reported `path != nil`:

1. Resolve Xcode pid via `NSRunningApplication`.
2. `AXUIElementCreateApplication(pid)` → app element.
3. `AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused)` → focused element (may be text area, navigator, etc).
4. `AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute, &rangeValue)` → AXValue of kAXValueCFRangeType. Read `CFRange { location: Int, length: Int }`. Discard `length`.
5. `AXUIElementCopyParameterizedAttributeValue(focused, kAXLineForIndexParameterizedAttribute, location as CFNumber, &lineValue)` → CFNumber, convert to Int.
6. Return Int + 1 (AX returns 0-based line, payload stores 1-based human line number) OR nil if any step fails.

**No document text is read.** AX returns Int directly via parameterized attribute.

**Failure modes:**
- AX trust revoked → `AXIsProcessTrusted()` false → skip line query, emit event without line field.
- Focused element not text area → step 4 returns kAXErrorNoValue → skip.
- Xcode not running / pid stale → step 2 fails → skip.

All failure modes emit `xcode_active_doc_changed` event without `line` field (zero regression on existing behavior).

### 3.4 JetBrains XML key attribute parsing

`recentProjects.xml` structure:

```xml
<application>
  <component name="RecentProjectsManager">
    <option name="additionalInfo">
      <map>
        <entry key="$USER_HOME$/Desktop/Leaf/leaf">
          <value>
            <RecentProjectMetaInfo>
              <option name="displayName" value="leaf" />
              <option name="activationTimestamp" value="1715800000000" />
              ...
```

T1 parser extracts `entry@key` → string `$USER_HOME$/Desktop/Leaf/leaf` → replace `$USER_HOME$` literal with `~` → `~/Desktop/Leaf/leaf` → emit as `workspace_root`.

Edge case: `key` may be `$PROJECT_DIR$/...` for IDE-relative refs (rare). Discard such entries (don't emit `workspace_root`) — only `$USER_HOME$/...` keys are home-anchored and expandable.

### 3.5 RecentCommitSnapshot type + SQL

```swift
// LeafCore/Insights/RecentCommitSnapshot.swift
public struct RecentCommitSnapshot: Equatable, Sendable {
    public let subject: String
    public let branch: String?
    public let atMs: Int64

    public init(subject: String, branch: String?, atMs: Int64) {
        self.subject = subject
        self.branch = branch
        self.atMs = atMs
    }
}
```

```swift
// DerivedInsights protocol method (public)
func recentLastCommit(maxAgeMs: Int64) throws -> RecentCommitSnapshot?

// StubInsights default — return nil
func recentLastCommit(maxAgeMs: Int64) throws -> RecentCommitSnapshot? { nil }

// ProdInsights+LastCommit.swift (LeafCorePrivate moat) — real query body
// lives in the moat. Conceptually: fetch the most-recent `gh_commit_pushed`
// event from the action stream within `maxAgeMs`, ordered newest first,
// limit 1, then decode payload_json → RecentCommitSnapshot {subject, branch, atMs}.
```

Note: the event-kind discriminator pattern reuses the existing approach from `ProdInsights+TodayMetrics.queryPills`. Uses existing index `idx_events_signal_type_ts`. Future micro-optimization: separate `event_kind` virtual column or partial index — out of T1 scope.

### 3.6 Settings UI

Two new rows in `SystemObserversSettingsSection.swift`:

```swift
// New SystemObserverDescriptor entries appended to Self.observers array
SystemObserverDescriptor(
    id: "ax-line-capture",
    displayName: "Xcode line capture",
    explainer: "Capture cursor line in active document via Accessibility. Used by Home YOU·NOW to show cursor position.",
    sfSymbol: "text.cursor",
    requiresInputMonitoring: false,
    bindingKeyPath: \.axLineCaptureEnabled,
),
SystemObserverDescriptor(
    id: "ide-workspace-path-tracking",
    displayName: "IDE workspace path tracking",
    explainer: "Record workspace path (~/path/to/project) for VSCode-family and JetBrains. Used by Home YOU·NOW to derive branch and Linear ID.",
    sfSymbol: "folder.badge.gearshape",
    requiresInputMonitoring: false,
    bindingKeyPath: \.ideWorkspacePathTrackingEnabled,
),
```

Existing `LocalAppsStore` pattern reused:

```swift
// LocalAppsStore.swift +2 properties
public static let axLineCaptureEnabledKey = "systemObservers.axLineCaptureEnabled"
public static let ideWorkspacePathTrackingEnabledKey = "systemObservers.ideWorkspacePathTrackingEnabled"

public var axLineCaptureEnabled: Bool {
    get { defaults.object(forKey: Self.axLineCaptureEnabledKey) as? Bool ?? true }
    set {
        defaults.set(newValue, forKey: Self.axLineCaptureEnabledKey)
        DispatchQueue.main.async { [self] in self.objectWillChange.send() }
    }
}

public var ideWorkspacePathTrackingEnabled: Bool {
    get { defaults.object(forKey: Self.ideWorkspacePathTrackingEnabledKey) as? Bool ?? true }
    set {
        defaults.set(newValue, forKey: Self.ideWorkspacePathTrackingEnabledKey)
        DispatchQueue.main.async { [self] in self.objectWillChange.send() }
    }
}
```

Default `true` via `defaults.object(...) as? Bool ?? true` idiom (vs `defaults.bool(...)` which always defaults to `false`).

**Gating at emission boundary:**
- `ProdXcodeAdapter` reads `LocalAppsStore.shared.axLineCaptureEnabled` before AX line query. If `false` → skip AX calls, set `observation.line = nil`.
- `VSCodeWorkspaceWatcher.buildEvent` accepts `workspaceRootEnabled: Bool` parameter (passed by caller `LeafAgent`). If `false` → skip `workspace_root` payload field.
- `JetBrainsRecentProjectsWatcher.buildEvent` — same gating pattern.

Toggle OFF → field gracefully absent from payload. Downstream consumers (T5/T7) handle Optional/missing field naturally.

---

## 4. Privacy walkback

Per master spec §6 invariants + ADR-010:

| Field | Walkback discipline | Sentinel test |
|---|---|---|
| `xcode_active_doc_changed.line` | Int row index. NO document text read. `AXLineForIndex` returns Int directly via parameterized attribute. | `test_t1_walkback_xcodeActiveDocChanged_lineNeverLeaksContent` — inject `LEAKED_SENTINEL_XCODE_T1_LINE_BODY` into focused element's `kAXValueAttribute` mock, verify payload `.line` is Int + no other field carries sentinel. |
| `vscode_workspace_opened.workspace_root` | Tilde-prefixed (`~/...`). `sanitizedPath` already computed by `parseWorkspaceJSON`. Walkback contract amended to allow tilde form. | `test_t1_walkback_vscodeWorkspaceOpened_workspaceRootIsTilde` — inject `LEAKED_SENTINEL_VSCODE_T1_USER` into mock `homeDir` parameter, verify `workspace_root` field starts with `~/` + does not contain `/Users/LEAKED_SENTINEL_VSCODE_T1_USER/`. |
| `jetbrains_recent_project_observed.workspace_root` | Same as VSCode. `$USER_HOME$` literal in XML → `~` replacement at parser. | `test_t1_walkback_jetbrainsRecentProjectObserved_workspaceRootIsTilde` — XML with `<entry key="$USER_HOME$/LEAKED_SENTINEL_JB_T1_PROJECT">`, verify `workspace_root` = `~/LEAKED_SENTINEL_JB_T1_PROJECT` (literal sentinel allowed; expansion not performed at emission). |

**Integration sweep:** `test_t1_walkback_integrationSentinelSweep` — constructs all 3 events with sentinel strings injected at each forbidden position; iterates `event.payload` keys+values; asserts no forbidden sentinel reaches payload.

Walkback contract update site:

```swift
// VSCodeWorkspaceWatcher.swift lines 9-15 — AMENDED
/// Privacy walkback at parser boundary:
///   1. URL-decode percent escapes.
///   2. Replace $HOME prefix with `~/`.
///   3. Resolve against watched-folder bookmarks.
///   4. Inside-watched → payload {workspace_name (basename), watched_folder_id, outside_watched_folder=false, workspace_root (~/-prefixed)}.
///   5. Outside-watched → payload {workspace_name (basename), outside_watched_folder=true, workspace_root (~/-prefixed)}.
///   6. MAY emit tilde-prefixed sanitized workspace path (~/...) for substrate consumers' git-HEAD walk.
///   7. NEVER bare absolute path with $HOME username (/Users/<name>/...) in payload.
```

Existing P6 sentinel test `test_p6_walkback_vscodeWorkspaceOpened_pathNeverLeaks` continues to pass because it asserts `/Users/alice` absolute prefix doesn't leak — T1 emits `~/...` form which contains no `/Users/`, so existing sentinel string `LEAKED_SENTINEL_VSCODE_P6_PATH` (injected as part of absolute path) does NOT appear in `workspace_root` (only its tilde-stripped tail does).

Wait — closer look: existing P6 test injects sentinel into `workspace.json` `folder` URI as `file:///Users/alice/Desktop/SENTINEL`. After `parseWorkspaceJSON`, `sanitizedPath` = `~/Desktop/SENTINEL` (sentinel survives in basename of path). Currently `workspace_root` is NOT emitted, so test passes. After T1, `workspace_root` = `~/Desktop/SENTINEL` — sentinel IS in payload at this position. **Existing test would now fail** because it asserts sentinel never appears in any payload field.

**Resolution:** P6 sentinel test needs update — assertion changes from "sentinel string never in any payload field" to "absolute path prefix `/Users/` never in any payload field". OR introduce dedicated T1 sentinel `LEAKED_SENTINEL_VSCODE_T1_USER` and inject it INTO THE USERNAME POSITION (`file:///Users/LEAKED_SENTINEL_VSCODE_T1_USER/Desktop/myws`), so after sanitize the sentinel is REMOVED (`~/Desktop/myws`).

T1 takes the second option — new sentinels target the username position specifically (which IS forbidden to leak), preserving existing P6 test invariant via path-name sentinel as-is.

Existing P6 test sentinel `LEAKED_SENTINEL_VSCODE_P6_PATH` is in PATH SUFFIX (basename position) — that sentinel SHOULD appear in `workspace_name` (basename) and now also in `workspace_root` (tilde-prefixed). Existing test would need adjustment to acknowledge sentinel CAN appear in path-basename payload fields. T1 implementation must:

1. Update existing P6 test `test_p6_walkback_vscodeWorkspaceOpened_pathNeverLeaks` assertion: rename the sentinel constant + assertion to target USERNAME position specifically.
2. OR add T1 sentinel separately + leave P6 test alone — accepting that P6 test's "any payload field" sweep needs adjustment.

**Decision:** option 1 — rename P6 sentinel constant to `LEAKED_SENTINEL_VSCODE_USERNAME` (semantic name) and inject it into the username position. Move assertion to "sentinel substring `LEAKED_SENTINEL_VSCODE_USERNAME` never appears in any payload field". Path-basename position uses different sentinel and is allowed to appear. This is a same-commit refactor — P6 test invariant updated to reflect post-T1 walkback semantics.

---

## 5. Testing

### 5.1 Unit tests

| Test name | File | Coverage |
|---|---|---|
| `testXcodeStateMachineEmitsLineWhenAvailable` | `XcodeStateMachineTests.swift` | `XcodeObservation(line: 142)` → `events[0].payload["line"] == "142"` |
| `testXcodeStateMachineOmitsLineWhenNil` | `XcodeStateMachineTests.swift` | `XcodeObservation(line: nil)` → `events[0].payload["line"] == nil` |
| `testVSCodeWorkspaceWatcherEmitsWorkspaceRoot` | `VSCodeWorkspaceWatcherTests.swift` | `buildEvent(..., sanitizedPath: "~/Desktop/foo")` → `event.payload["workspace_root"] == "~/Desktop/foo"` |
| `testJetBrainsParserExtractsWorkspaceRootFromKeyAttribute` | `JetBrainsRecentProjectsWatcherTests.swift` | XML with `<entry key="$USER_HOME$/Desktop/foo">` → parser yields entry with `workspaceRoot == "~/Desktop/foo"` |
| `testJetBrainsParserSkipsProjectDirEntries` | `JetBrainsRecentProjectsWatcherTests.swift` | XML with `<entry key="$PROJECT_DIR$/...">` → no `workspace_root` emitted |
| `testRecentLastCommitReturnsLatestCommit` | `ProdInsightsLastCommitTests.swift` (new file in `LeafCorePrivateTests`) | Fixture DB: 3 `gh_commit_pushed` events at t=100/200/300 ms → `recentLastCommit(maxAgeMs: 1000)` returns t=300 with correct subject/branch |
| `testRecentLastCommitReturnsNilWhenOlderThanMaxAge` | same | Event at t=100 ms, `nowMs ≈ 1715800000000`, `maxAgeMs=1000` → nil |
| `testRecentLastCommitReturnsNilWhenNoCommits` | same | Empty DB → nil |
| `testStubInsightsReturnsNilForRecentLastCommit` | `DerivedInsightsTests.swift` | `StubInsights().recentLastCommit(maxAgeMs: 60_000)` → nil |
| `testRecentCommitSnapshotRoundTrips` | new `RecentCommitSnapshotTests.swift` | Equatable + Sendable conformance + init param round-trip |

### 5.2 Sentinel-injection regression tests

4 new tests in `RelayBodyLeakageTests.swift`:

| Test name | Sentinel constant | Injection point | Assertion |
|---|---|---|---|
| `test_t1_walkback_xcodeActiveDocChanged_lineNeverLeaksContent` | `LEAKED_SENTINEL_XCODE_T1_LINE_BODY` | Mock AX text-content attribute | `event.payload["line"] is Int-valued string` AND no payload field contains `LEAKED_SENTINEL_XCODE_T1_LINE_BODY` |
| `test_t1_walkback_vscodeWorkspaceOpened_workspaceRootIsTilde` | `LEAKED_SENTINEL_VSCODE_T1_USER` | `homeDir` parameter to `parseWorkspaceJSON` (simulates username position) | `event.payload["workspace_root"]` starts with `~/` AND does not contain `LEAKED_SENTINEL_VSCODE_T1_USER` |
| `test_t1_walkback_jetbrainsRecentProjectObserved_workspaceRootIsTilde` | `LEAKED_SENTINEL_JB_T1_PROJECT` (in PROJECT BASENAME position — sentinel CAN appear here) + `LEAKED_SENTINEL_JB_T1_USER` (in username position via mock $USER_HOME$ substitution — must NOT appear) | XML body | `workspace_root` == `~/LEAKED_SENTINEL_JB_T1_PROJECT` (basename sentinel survives, expected); username sentinel never anywhere |
| `test_t1_walkback_integrationSentinelSweep` | All 3 sentinels above | All 3 emission paths | iterate `event.payload` for each of 3 events, assert no forbidden sentinel (username position) ever appears |

**P6 test adjustment in same commit:** rename `LEAKED_SENTINEL_VSCODE_P6_PATH` → `LEAKED_SENTINEL_VSCODE_USERNAME` (semantic), move sentinel string from path basename → username position, adjust assertion to reflect post-T1 walkback semantics.

### 5.3 Integration tests

| Test name | Coverage |
|---|---|
| `testRecentLastCommitIntegration` | Write 3 synthetic `gh_commit_pushed` events to fixture DB via DB writer → `ProdInsights(database:).recentLastCommit(maxAgeMs: 4*60*60*1000)` returns snapshot matching latest |
| `testT1PayloadFieldsPresentInFixtureEvents` | Synthetic Xcode + VSCode + JetBrains events via state-machine/watcher direct calls → `event.payload` round-trips through JSON encode/decode → expected fields present |

### 5.4 Verification gates (master spec §7.2)

1. **5/5 xcodebuild schemes** Debug build SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
2. **SPM tests green** — XCTest + Swift-Testing combined, 0 failures. Net new test count delta: +13 tests (10 unit + 4 sentinel - 1 renamed = +13 visible).
3. **`just check-tokens` 3-tier clean** — BASE + MIGRATION + RETIRED.
4. **Privacy walkback grep narrow scope** — files touched by T1: zero hits of forbidden field names (`absolute_path` outside allowlist / `full_comment_body` / `raw_email` / `notes_body` / `file_contents` / `raw_prompt` / `tool_input` / `tool_response` / `response_body`).
5. **4 sentinel-injection tests green** + renamed P6 test green.
6. **HomeView.swift LOC** — unchanged from P9 (≤280 LOC budget preserved). T1 doesn't touch HomeView.

---

## 6. Acceptance criteria

| AC | Description |
|---|---|
| AC-1 | `xcode_active_doc_changed.line: Int?` Optional payload field emitted when AX text-area focused; omitted otherwise. |
| AC-2 | `vscode_workspace_opened.workspace_root: String` payload field is `~`-prefixed (never `/Users/<name>/...`). |
| AC-3 | `jetbrains_recent_project_observed.workspace_root: String` payload field is `~`-prefixed when XML key uses `$USER_HOME$/...`; absent when key uses `$PROJECT_DIR$/...` or non-home-anchored prefix. |
| AC-4 | `DerivedInsights.recentLastCommit(maxAgeMs:)` returns most-recent `gh_commit_pushed` event within `maxAgeMs` window, or nil. |
| AC-5 | `RecentCommitSnapshot` struct lives in `Packages/LeafCore/Sources/LeafCore/Insights/RecentCommitSnapshot.swift`. |
| AC-6 | `ProdInsights+LastCommit.swift` lives in `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Insights/`. |
| AC-7 | `StubInsights.recentLastCommit` returns nil. |
| AC-8 | 4 new sentinel-injection tests in `RelayBodyLeakageTests` green. |
| AC-9 | Renamed P6 sentinel constant + adjusted assertion green. |
| AC-10 | `LocalAppsStore.axLineCaptureEnabled` + `LocalAppsStore.ideWorkspacePathTrackingEnabled` default ON when no UserDefaults key written. |
| AC-11 | Settings → System Observers renders 2 new toggle rows below existing IDE storage sub-section. Toggles bind correctly. |
| AC-12 | Toggle OFF for `axLineCaptureEnabled` → AX line query skipped, payload omits `line` field. |
| AC-13 | Toggle OFF for `ideWorkspacePathTrackingEnabled` → `workspace_root` field omitted from both VSCode + JetBrains payloads. |
| AC-14 | `git diff feature/track-9-substrate -- Packages/LeafCore/Sources/LeafCore/DB/ Packages/LeafCorePrivate/Sources/LeafCorePrivate/DB/` returns empty (zero SQLCipher migration delta). |
| AC-15 | `git diff feature/track-9-substrate -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` shows 0 added enum cases or default entries. |
| AC-16 | `git diff feature/track-9-substrate -- Packages/LeafCore/Sources/LeafCore/MCP/ LeafMCP/` returns empty (zero MCP tool delta). |
| AC-17 | Privacy walkback narrow grep — 0 hits forbidden fields in T1 file scope. |
| AC-18 | 5/5 xcodebuild schemes Debug build SUCCESS. |
| AC-19 | SPM tests green; net new test count delta +13 vs T1-baseline. |
| AC-20 | `just check-tokens` 3-tier clean. |
| AC-21 | HomeView.swift LOC unchanged (≤280). |
| AC-22 | DispatchCoverageTests parity fences unchanged + green (no new event_kinds → no new fence entries). |

---

## 7. Out of scope (deferred to subsequent phases)

- **T5 — YOU·NOW branch deriver UI impl** (`currentTaskIdentity()` per-IDE dispatch reading T1 payload fields → `.git/HEAD` walk → branch + LinearIDExtractor → emit `branch` + `linearID` in YOU·NOW snapshot). YouNowBlock UI surface for `.active`-state line 2 rendering.
- **T7 — `WhereStoppedSnapshot.{anchorFilePath, anchorLine, recentLastCommit}`** field additions + `ProdWhereStoppedDeriver` extension. M028 `where_stopped_log` migration (add `anchor_file_path TEXT NULL` + `anchor_line INTEGER NULL` columns OR resolve via deriver-side JOIN against `events.payload_json`). WhereStoppedBlock 4-line layout.
- **`vscode_active_doc_changed.workspace_root`** — master spec §5.1 deviation. T5 deriver consumes via `vscode_workspace_opened` DB-join.
- **VSCode/JetBrains AX line capture** — Electron AX surfaces vary per renderer pid; JBR custom AX implementations not consistent. Carry post-Track-9 as IDE-specific extension.
- **AI subagent failure detector** — Phase 4.9 AI rollup, separate phase.
- **`get_weekly_metrics` MCP tool** — future post-Track-9 if requested.

---

## 8. References

- Track-9 master design: [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md)
- Track-6 P2 Xcode collector: `Packages/LeafCore/Sources/LeafCore/OS/XcodeStateMachine.swift`
- Track-6 P6 IDE collectors: `Packages/LeafCore/Sources/LeafCore/Collectors/VSCodeWorkspaceWatcher.swift` + `JetBrainsRecentProjectsWatcher.swift` + `Insights/Parsers/VSCodeFamily/`
- AX precedent: `Packages/LeafCore/Sources/LeafCore/Insights/AttentionEmissionPlanner.swift` + `WindowContextProvider` protocol + LeafAgent `AXWindowContextProvider`
- DerivedInsights API surface: `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift`
- ProdInsights moat: `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Insights/`
- ShareEventTypeKey registry: `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift`
- LocalAppsStore: `Packages/LeafCore/Sources/LeafCore/Share/LocalAppsStore.swift`
- Settings UI: `Leaf/Views/Window/Settings/SystemObserversSettingsSection.swift`
- Sentinel-injection lineage: `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift`

---

## 9. Workflow

Per `.claude/shared/conventions.md` § "Одна phase = одна сессия", 8-stage workflow.

- **Stage 1 Discovery** — DONE (this session, 6 Explore subagent reports).
- **Stage 2 Brainstorm** — DONE (this session, user delegated tactical decisions; design consolidated in §2 above).
- **Stage 3 Spec write** — DONE (this document).
- **Stage 4 Plan write** — NEXT step in this session via `superpowers:writing-plans`.
- **Stage 5..8** — separate session per conventions.md "one phase = one session" mandate. Stage 5 Implementation (TDD per step), Stage 6 Independent review, Stage 7 Verification, Stage 8 Ship (FF to `feature/track-9-substrate`, `docs(shared)` commit `Track-9 T1 landed — current-state update`).
