# Track 6 P6 — IDEs Surface Cap (vscode + JetBrains) · Spec

**Phase:** Track-6 P6 — closes Track-6.
**Stage:** 3 — Spec (post-brainstorm sign-off 2026-05-16).
**Branch:** `feature/track-6-P6-ides-cap` (off main `9b2a53b`).
**Anchors:**
- Contract — `2026-05-15-track-6-existing-surface-depth-contract.md`.
- Stage 0 + 1 research — `2026-05-16-track-6-P6-ides-cap-research.md` (Q8a/b/c answers in §11.1, substrate verification in §11.2).

This is a **hybrid code+doc phase** — small code surface (1 parser layer + 2 FSEvents watchers + 1 classifier cleanup + 4 event_kinds), substantial documentation surface (whitepaper won't-list + re-evaluation triggers + architecture clarification). Mirrors P7's shape with non-trivial code.

---

## 1. Goal

Bring vscode (+ Cursor / Insiders / VSCodium) and JetBrains IDEs from current "surface" depth (L1 attention only for vscode, S2 single-kind active-doc for JetBrains) to the **realistic ceiling reachable without plugin/extension** — and ratify that ceiling explicitly in the whitepaper.

**Concretely.** P6 ships **four new event_kinds**:

1. `vscode_active_doc_changed` — bundle-ID-aware parsed payload `(workspace_name, file_basename)` from AX window title for vscode-family bundles.
2. `vscode_workspace_opened` — FSEvents on `workspaceStorage/<hash>/` parent dir CREATE → load `workspace.json` → emit basename + watched-folder gate.
3. `jetbrains_recent_project_observed` — FSEvents on per-IDE-per-version `recentProjects[Directories].xml` → emit project basename + activation timestamp + IDE-version-dir.
4. `ide_window_title_observed` — fallback when `vscode_active_doc_changed` parser fails to recognize title shape (user customized `window.title`, new fork, locale variant). Default OFF, planner sanitizes path-like substrings before emit.

**JetBrains bundle list cleanup**: remove `com.jetbrains.AppCode` (EOL Dec 2023), add DataGrip + RustRover + DataSpell. Fleet deferred to acceptance-gate AS-probe.

**Documentation ratification**: whitepaper won't-list entry "IDE deep integration без plugin/extension", glossary entries "IDE surface ceiling" + "Layer D V2", re-evaluation trigger list, architecture.md Layer A clarification.

## 2. Scope

### 2.1 In scope

- **Parser layer.** `AttentionEmissionPlanner` extension dispatching to per-fork parsers (Option A in brainstorm Section A — single source of truth, no separate adapter).
- **Per-fork parser files (4):** `VSCodeStableParser`, `CursorParser`, `VSCodeInsidersParser`, `VSCodiumParser`. Shared protocol `VSCodeFamilyTitleParser` + shared regex helper.
- **State machine** (vscode-family). Per-bundle-ID `StateMachineBox` keyed by `(bundleID, workspace, doc_basename)` tuple — mirrors S2 JetBrains pattern.
- **FSEvents watchers (2):** `VSCodeWorkspaceWatcher` on `~/Library/Application Support/{Code,Cursor,Code - Insiders,VSCodium}/User/workspaceStorage/`; `JetBrainsRecentProjectsWatcher` on `~/Library/Application Support/JetBrains/` parent + sub-watchers on `<Product><Y>/options/`.
- **Classifier additions:** `com.microsoft.VSCodeInsiders` to `ProdAppCategoryClassifier.dev` Set. `com.jetbrains.AppCode` removal.
- **JetBrains bundle list rotation:** `-AppCode, +DataGrip, +RustRover, +DataSpell` in `ProdJetBrainsAdapter.targetBundleIDs`.
- **Privacy walkbacks (4 sentinels):** PATH, TITLE, FILE_BODY, CONSOLE_OUTPUT.
- **Tests:** parser units, state-machine units, FSEvents watcher units, `RelayBodyLeakageTests` extensions, `DispatchCoverageTests` parity-fence extensions, `ActivityFeedMapper.mapLocalOS` switch additions.
- **Documentation:** Stage 8 `docs(shared)` commit + `/sync-docs` whitepaper push.

### 2.2 Out of scope (deferred or forbidden)

- vscode/Cursor/JetBrains **plugin/extension** work — Layer D V2 separate track (whitepaper won't-list ratifies this).
- vscode `state.vscdb` SQLite reads — locking-hostile + zero added value over FSEvents on `workspaceStorage/` (research §2.4).
- VSCode CLI `code --status` shellout — Agent does not exec user-installed binaries (research §2.9).
- LSSharedFileList probes — deprecated + vendor-internal (research §2.8).
- `recentProjects.xml` (JetBrains) **content** parsing beyond `(displayName, activationTimestamp)` extraction — frame state, run config, scheme list, debugger state forbidden.
- Per-product JetBrains event_kind discriminators (`pycharm_active_doc_changed`, etc) — `ide_bundle_id` payload field discriminates without registry bloat.
- Fleet (`com.jetbrains.fleet`) — AS-dictionary support unverified, defer to acceptance-gate probe.
- VSCode forks beyond MVP four (Code OSS, OpenVSCode-server, proprietary forks) — v1.1 follow-ups, low audience.
- New MCP tools (contract §4 default).
- New migrations (Schema unchanged).
- Cross-link substrate additions (Track-1 `event_links` kinds unchanged).

## 3. Architecture

### 3.1 Discrimination layer — planner-level (brainstorm Section A)

**Substrate today** (research §11.2 Fact #2): `AttentionEmissionPlanner.plan(...)` returns `RawEvent(signalType: .attention, bundleID, payload: {window_title?, browser_url?})`. Mapper dispatches on `(signalType, bundleID)`, no `event_kind` key in payload.

**P6 extension:** planner gains a per-bundle-family parser hook after successful AX-read. For vscode-family bundle IDs (`com.microsoft.VSCode`, `com.todesktop.230313mzl4w4u92`, `com.microsoft.VSCodeInsiders`, `com.visualstudio.code.oss`) the planner invokes the corresponding `VSCodeFamilyTitleParser`. On parse success: payload gains `event_kind: "vscode_active_doc_changed"` + `workspace_name` + `file_basename`. On parse failure: payload gains `event_kind: "ide_window_title_observed"` + sanitized `raw_title` (default OFF in registry).

**Why planner-level (not separate adapter):**
- Single AX-read source of truth — no duplicate AX hierarchy walks.
- Reuses windowPoll cadence (event-driven via NSWorkspace activation + idle window tick).
- No suppression-logic coordination between adapter and planner.
- Architectural asymmetry with JetBrains is **vendor-driven**, not our choice: JetBrains exposes AppleScript dictionary (research §2.6) → adapter pattern natural; vscode does not (research §2.1) → AX-only.

**Boundary discipline:** planner-level parser is **decision layer only** (pure function on title string + bundle ID). No AX reads inside parser, no I/O. State machine sits adjacent in planner-companion module.

### 3.2 State machine — vscode-family

Mirrors S2 `JetBrainsStateMachine` per-bundle `StateMachineBox` pattern. Keyed by `bundleID` (Box dict), each box stores last-observed `(workspace_name, file_basename)` tuple. On planner emission tick, parser yields tuple → state machine compares against prev → emits RawEvent **only on diff** (workspace change OR file change OR transition from generic-attention to parsed).

**Shape:**

```
public actor VSCodeStateMachine {
    private var boxes: [String: VSCodeObservation] = [:]  // keyed by bundleID

    public func observe(
        bundleID: String,
        observation: VSCodeObservation,
        now: Date
    ) -> RawEvent? {
        let prev = boxes[bundleID]
        if prev == observation { return nil }
        boxes[bundleID] = observation
        return makeEvent(bundleID: bundleID, observation: observation, now: now)
    }
}

public struct VSCodeObservation: Equatable {
    public let workspaceName: String?
    public let fileBasename: String?
}
```

Lives at `Packages/LeafCore/Sources/LeafCore/OS/VSCodeStateMachine.swift` mirror to `JetBrainsStateMachine.swift`.

### 3.3 Per-fork parser files (brainstorm Section B)

Shared protocol + 4 concrete parsers under `Packages/LeafCore/Sources/LeafCore/Insights/Parsers/VSCodeFamily/`:

```
VSCodeFamilyTitleParser.swift   — protocol + shared regex helper
VSCodeStableParser.swift        — appName regex: "Visual Studio Code"
CursorParser.swift              — appName regex: "Cursor"
VSCodeInsidersParser.swift      — appName regex: "Visual Studio Code - Insiders"
VSCodiumParser.swift            — appName regex: "VSCodium" | "Codium"
```

**Protocol:**

```
public protocol VSCodeFamilyTitleParser {
    static var appNameRegex: String { get }
    static var bundleID: String { get }
    static func parse(_ title: String) -> VSCodeObservation?
}
```

**Shared helper** (`parseDefaultFormat`) covers vscode default `window.title`:
```
^(?<dirty>●\s+)?(?<file>[^—-]+?)\s+[—-]\s+(?<root>[^—-]+?)\s+[—-]\s+(?<app>APP_NAME)$
```
Plus single-file-mode fallback `^(?<file>[^—-]+?)\s+[—-]\s+(?<app>APP_NAME)$` (no `${rootName}` segment).

Each concrete parser supplies its `appNameRegex` literal, calls helper. Distinct files allow future per-fork divergence without growing the shared helper.

**Why 4 files, not generic-parameterized:** Q8c — vendor-specific edge cases over time will diverge (Cursor's specific title customizations, Insiders' beta-of-the-week format shifts). Per-fork file = drop-in addition without touching base parser.

### 3.4 FSEvents — vscode workspace-opened watcher

`VSCodeWorkspaceWatcher` actor at `Packages/LeafCore/Sources/LeafCore/Collectors/VSCodeWorkspaceWatcher.swift`.

**Watch paths (initial):**
- `~/Library/Application Support/Code/User/workspaceStorage/`
- `~/Library/Application Support/Cursor/User/workspaceStorage/`
- `~/Library/Application Support/Code - Insiders/User/workspaceStorage/`
- `~/Library/Application Support/VSCodium/User/workspaceStorage/`

Each watch path → parent dir watched for `kFSEventStreamEventFlagItemCreated` on subdirs. On CREATE: load `<new-hash-dir>/workspace.json` (plain JSON, unlocked, atomic write per vscode upstream), URL-decode `folder` URI, home-dir sanitize, watched-folder resolve.

**Cold path** (Agent start): no replay — only watch from `now`. Existing `workspaceStorage/<hash>/` dirs are historical, capturing them on Agent start would generate a flood of `vscode_workspace_opened` events with stale timestamps. Skip historical scan.

**Privacy walkback at parser boundary:**

1. URL-decode percent escapes (`%2F` → `/`, `%3A` → `:`, etc).
2. Replace `$HOME/` prefix with `~/` (already a moat pattern in `ActivityFeedMapper.basename()`).
3. Resolve against watched-folder bookmarks (`WatchedFolderStore.resolve(path:) -> WatchedFolder?`).
4. If matched: payload `{event_kind, ide_bundle_id, workspace_name (basename), watched_folder_id (UUID), outside_watched_folder: false}`.
5. If unmatched: payload `{event_kind, ide_bundle_id, workspace_name (basename only — NO path), outside_watched_folder: true}`.

**TCC posture**: zero new prompt — `~/Library/Application Support/<vendor>/` is outside FDA umbrella, P3 BrowserBookmarksWatcher pattern confirmed.

### 3.5 FSEvents — JetBrains recent-projects watcher (brainstorm Section E)

`JetBrainsRecentProjectsWatcher` actor at `Packages/LeafCore/Sources/LeafCore/Collectors/JetBrainsRecentProjectsWatcher.swift`.

**Discovery cadence:** FSEvents on parent `~/Library/Application Support/JetBrains/` + one-time initial glob on Agent start. Mirrors P3 Chrome multi-profile pattern.

**Initial glob (Agent start):**

```
glob: ~/Library/Application Support/JetBrains/<Product><YYYY.N>/options/recentProjects.xml
glob: ~/Library/Application Support/JetBrains/<Product><YYYY.N>/options/recentProjectDirectories.xml
```

For each match → register FSEvents stream on the xml file (or its parent dir `options/`) for UPDATE events.

**FSEvents on parent:** on CREATE of new `<Product><Y>/` dir (user installs new IDE OR annual version bump) → wait short debounce (500ms) → glob for `options/recentProjects*.xml` → register new stream.

**On xml UPDATE:** atomic-write-safe (JetBrains writes recentProjects.xml on project close + project switch), parse via `XMLParser`, extract `RecentProjectMetaInfo` entries → diff against last snapshot (in-memory) → emit `jetbrains_recent_project_observed` for entries with new `activationTimestamp`.

**Per-IDE-per-version inference:** path component `JetBrains/<Product><YYYY.N>/` → derive `ide_version_dir` payload field (e.g. `"PyCharm2025.1"`). Bundle ID inferred via product-name → bundle-ID mapping table:

```
"IntelliJIdea"   → "com.jetbrains.intellij"
"IdeaIC"         → "com.jetbrains.intellij.ce"
"PyCharm"        → "com.jetbrains.pycharm"
"PyCharmCE"      → "com.jetbrains.pycharm.ce"
"WebStorm"       → "com.jetbrains.WebStorm"
"GoLand"         → "com.jetbrains.goland"
"CLion"          → "com.jetbrains.CLion"
"Rider"          → "com.jetbrains.rider"
"RubyMine"       → "com.jetbrains.rubymine"
"PhpStorm"       → "com.jetbrains.PhpStorm"
"DataGrip"       → "com.jetbrains.datagrip"
"RustRover"      → "com.jetbrains.rustrover"
"DataSpell"      → "com.jetbrains.dataspell"
```

Lives in private adapter file (`LeafCorePrivate/Prod/Collectors/Apple/ProdJetBrainsProductMap.swift`) — moat (per-version dir convention is implementation detail).

**Privacy walkback** identical to vscode workspace-opened: URL-decode, home-dir sanitize, watched-folder resolve, basename-only emit.

**XML parsing safety:** XMLParser (Foundation), strict mode, max depth 8, max element count 10K. Recover from malformed xml gracefully (log + skip diff this tick).

### 3.6 Fallback event_kind — `ide_window_title_observed` (brainstorm Section H)

When `VSCodeFamilyTitleParser.parse(title:)` returns nil for an L3+ vscode-family bundle (user customized `window.title`, locale variant, new fork shape), planner emits fallback event_kind instead of dropping silently.

**Payload:** `{event_kind: "ide_window_title_observed", ide_bundle_id, raw_title}`.

**Planner path-sanitizer** applied uniformly before emit (defense-in-depth):
- Replace `$HOME/` → `~/` (home-dir prefix).
- For each `/`-containing substring: take last component (basename).
- Apply to entire title string token-by-token (split on whitespace, sanitize each token).

**Registry posture:** `ShareEventTypeKey.ideWindowTitleObserved`, default OFF. Documented as "debug/diagnostics; raw window title from IDE forks unknown to current parsers".

**Why fallback over silent drop:**
- Operational value: user reports "vscode active doc not showing in Activity tab" → enable fallback toggle → see raw title → diagnose mismatch without grep'ing Agent logs.
- New fork onboarding: drop in fallback signal, observe shapes in field, write parser without releasing first.
- Default OFF + path-sanitize = zero noise + bounded leakage attack surface.

### 3.7 Bundle classification cleanup (brainstorm Section C + F)

**`Packages/LeafCorePrivate/Prod/Insights/ProdAppCategoryClassifier.swift:32-47` (private):**
- `+` `"com.microsoft.VSCodeInsiders"` to `dev` Set.
- `-` `"com.jetbrains.AppCode"` from `dev` Set (EOL Dec 2023).

**`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/Apple/ProdJetBrainsAdapter.swift` (private, S2 baseline):**
- `-` `"com.jetbrains.AppCode"` from `targetBundleIDs`.
- `+` `"com.jetbrains.datagrip"`, `+` `"com.jetbrains.rustrover"`, `+` `"com.jetbrains.dataspell"`.

Net JetBrains bundle count: 11 - 1 + 3 = **13**.

**Single commit** for both changes — diff reads coherently as "P6 IDE bundle list rotation + AppCode cleanup".

### 3.8 ShareEventTypeRegistry additions

`Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift`:

```
.vscodeActiveDocChanged
.vscodeWorkspaceOpened
.jetbrainsRecentProjectObserved
.ideWindowTitleObserved
```

All **default OFF** per ADR-020 + Track-3/4 pattern. Registry baseline 152 → **156**. Contract §6.2 estimate "order of ~3"; +4 is one entry over — flagged in Stage 7 acceptance review (within tolerance per contract "order of" language; Q8b user choice for `vscode_workspace_opened` + brainstorm Section H fallback both legitimate additions).

### 3.9 ActivityFeedMapper additions

`Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift:442+` — extend `trackFourLocalOSKinds` whitelist + `mapLocalOS` switch:

```
case "vscode_active_doc_changed":
    return ActivityRow(
        primary: "VSCode: \(workspace) — \(file)",
        secondary: appName(from: ide_bundle_id),  // "VSCode" / "Cursor" / "Insiders" / "VSCodium"
        symbol: "chevron.left.forwardslash.chevron.right"
    )

case "vscode_workspace_opened":
    return ActivityRow(
        primary: "Opened workspace: \(workspace_name)",
        secondary: appName(from: ide_bundle_id),
        symbol: "folder.fill.badge.plus"
    )

case "jetbrains_recent_project_observed":
    return ActivityRow(
        primary: "JetBrains: \(project_name)",
        secondary: ide_version_dir,
        symbol: "chevron.left.forwardslash.chevron.right"
    )

case "ide_window_title_observed":
    // Fallback never renders in Activity tab — debug-only signal.
    // Skip in mapper (return nil), surface only in raw events query.
    return nil
```

**EventKindIcon** (`Packages/LeafCore/Sources/LeafCore/Insights/EventKindIcon.swift`): map `vscode_active_doc_changed` and `vscode_workspace_opened` to icons; `jetbrains_recent_project_observed` reuses existing JB icon; `ide_window_title_observed` → no icon (Activity-tab skip).

### 3.10 LocalAppsStore + Settings UI

Per contract §8 — Settings → Local Apps gains sub-toggles, Settings → System Observers gains FSEvents watcher toggles.

**FeatureGate protocol** `IDEStorageFeatureGate` (mirrors P3 `BrowserBookmarksFeatureGate`):

```
public protocol IDEStorageFeatureGate {
    var vscodeStorageEnabled: Bool { get async }
    var jetbrainsStorageEnabled: Bool { get async }
}
```

`LocalAppsStore` gains `@AppStorage` keys + UI rows:
- "VSCode workspace tracking" (Settings → System Observers → IDEs) — gates `VSCodeWorkspaceWatcher`
- "JetBrains recent projects" (same section) — gates `JetBrainsRecentProjectsWatcher`

Default both OFF (user opt-in mirrors P3 / Track-4 S3 posture).

## 4. Event vocabulary — detailed

### 4.1 `vscode_active_doc_changed`

| Field | Type | Source | Privacy |
|---|---|---|---|
| `event_kind` | string | literal | — |
| `ide_bundle_id` | string | NSWorkspace frontmost bundle ID | L1 |
| `workspace_name` | string (basename) | parsed from `${rootName}` segment | L3 |
| `file_basename` | string | parsed from `${activeEditorShort}` segment | L4 |

**ADR-010 walkbacks:** file contents, file path beyond basename, debugger state, console output, terminal text, search query, extension list, completion suggestion — all forbidden in payload. Sentinel test injects `LEAKED_SENTINEL_VSCODE_P6_FILE_BODY` into title `${activeEditorLong}` position and asserts payload `file_basename` is sanitized to basename only.

**Edge cases handled:**
- Single-file mode (no workspace): `workspace_name = nil`, `file_basename` only.
- Untitled buffer: `file_basename = "Untitled-1"` (matched as-is).
- Zen mode: title may strip activeEditor → parser returns nil → `ide_window_title_observed` fallback.
- Remote SSH workspace: title prefixed with `[SSH: host]` in `${rootName}` — parser strips bracket prefix from workspace_name.
- Customized `window.title`: parser fails → fallback path.

### 4.2 `vscode_workspace_opened`

| Field | Type | Source | Privacy |
|---|---|---|---|
| `event_kind` | string | literal | — |
| `ide_bundle_id` | string | derived from watch-path root | L1 |
| `workspace_name` | string (basename) | URL-decoded + home-sanitized basename of `folder` URI in `workspace.json` | L3 |
| `watched_folder_id` | string (UUID) | resolved against `WatchedFolderStore` | — |
| `outside_watched_folder` | bool | true if no `WatchedFolderStore` match | — |

**ADR-010 walkback:** full absolute path NEVER in payload (even when `outside_watched_folder=false`). Sentinel test injects `~/Desktop/SECRET-VSCODE-P6-PATH-MARKER` into `folder` URI and asserts payload contains only basename. `LEAKED_SENTINEL_VSCODE_P6_PATH`.

### 4.3 `jetbrains_recent_project_observed`

| Field | Type | Source | Privacy |
|---|---|---|---|
| `event_kind` | string | literal | — |
| `ide_bundle_id` | string | mapped from path component `<Product><Y>` | L1 |
| `ide_version_dir` | string | path component (e.g. `"PyCharm2025.1"`) | — |
| `project_name` | string (basename) | `<displayName>` element from XML | L3 |
| `activation_timestamp_ms` | int64 | `activationTimestamp` attribute | — |
| `outside_watched_folder` | bool | resolved against `WatchedFolderStore` (best-effort — JB recentProjects entries are paths) | — |

**ADR-010 walkback:** XML element body content NEVER read beyond `displayName` + `activationTimestamp`. No frame state, no run config, no scheme list, no debugger state. Sentinel test injects `<runManager><secret>LEAKED_SENTINEL_JB_P6</secret></runManager>` into XML and asserts payload omits.

### 4.4 `ide_window_title_observed`

| Field | Type | Source | Privacy |
|---|---|---|---|
| `event_kind` | string | literal | — |
| `ide_bundle_id` | string | NSWorkspace frontmost bundle ID | L1 |
| `raw_title` | string (sanitized, ≤200 chars) | AX title with path-sanitizer applied | L3 |

**Path sanitizer:** split title on whitespace, for each token containing `/` → take last `/`-component (basename); apply `$HOME/` → `~/` first. Truncation 200 chars enforced by existing planner discipline.

**ADR-010 walkback:** raw title may contain customized `${activeEditorLong}` — sanitizer kills full-path leak. Sentinel test injects title `Foo.swift — /Users/alice/secret/project — Visual Studio Code` and asserts `raw_title` payload contains `project` (basename) not full path. `LEAKED_SENTINEL_VSCODE_P6_TITLE`.

## 5. Schema

**No new migrations.** M001-M018 preserved.

`Schema.BodyKinds` not extended — vscode/JB events have no body-kind FTS dispatch (no user-authored body text fields).

## 6. Privacy contract — sentinel walkback inventory

`Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` extended with **four new sentinel walkbacks**:

1. `LEAKED_SENTINEL_VSCODE_P6_FILE_BODY` — inject into vscode title `${activeEditorLong}` position → assert `vscode_active_doc_changed.file_basename` is basename-only, no path or content.
2. `LEAKED_SENTINEL_VSCODE_P6_PATH` — inject into `workspace.json` `folder` URI as raw path with sentinel → assert `vscode_workspace_opened` payload has no full-path, basename only.
3. `LEAKED_SENTINEL_VSCODE_P6_TITLE` — inject into customized title → assert `ide_window_title_observed.raw_title` sanitized.
4. `LEAKED_SENTINEL_JB_P6` — inject into recentProjects.xml `<runManager>` child → assert `jetbrains_recent_project_observed` payload excludes.

Plus **integration-level walkback** (one test): sentinel-walk every RawEvent payload tree for all four event_kinds across realistic input fixtures. Pattern locked since Track-4 S4 fix-bundle.

## 7. Tests

### 7.1 Parser unit tests

`VSCodeFamilyTitleParserTests`:
- Default format VSCode stable, Cursor, Insiders, VSCodium — happy path each.
- Dirty indicator (`● `) prefix.
- Single-file mode (no rootName segment).
- Untitled buffer.
- Zen-mode stripped editor → returns nil.
- SSH remote prefix in workspace name.
- Customized `window.title` → returns nil (drives fallback).
- Unicode rootName (international characters).
- Em-dash vs hyphen separator.

### 7.2 State machine units

`VSCodeStateMachineTests`:
- New observation emits event.
- Identical observation suppresses emit.
- Workspace change emits, file unchanged.
- File change emits, workspace unchanged.
- Per-bundle isolation (vscode + Cursor concurrent boxes do not collide).
- Transition from generic-attention to parsed (first L3+ activation).

### 7.3 FSEvents watcher units

`VSCodeWorkspaceWatcherTests`:
- New `workspaceStorage/<hash>/` dir CREATE → `workspace.json` load → emit.
- URL-decoded path with `%2F` etc.
- Home-dir sanitize.
- Watched-folder match → `outside_watched_folder=false` + UUID payload.
- Watched-folder unmatched → `outside_watched_folder=true` + basename only.
- Malformed `workspace.json` → no emit + log.
- Race: dir CREATE before `workspace.json` written → retry with short backoff (500ms × 3), then drop.

`JetBrainsRecentProjectsWatcherTests`:
- Initial glob on Agent start → register streams per matched IDE-version dir.
- Parent dir CREATE (new IDE install) → 500ms debounce → glob → register sub-stream.
- xml UPDATE → parse → diff → emit per new `activationTimestamp` entry.
- Both `recentProjects.xml` and `recentProjectDirectories.xml` covered.
- Malformed xml → no emit + log.
- IDE-version dir → bundle ID mapping for all 13 supported IDEs + unknown product → skip.

### 7.4 DispatchCoverageTests parity-fence extension

Add four new event_kinds to `trackFourLocalOSKinds` list. Parity-fence test asserts `(trackFourLocalOSKinds ∩ ShareEventTypeKey.all) == trackFourLocalOSKinds`.

### 7.5 ActivityFeedMapper unit tests

`ActivityFeedMapperLocalOSTests`:
- `vscode_active_doc_changed` → `"VSCode: leaf — Foo.swift"` row.
- `vscode_workspace_opened` → `"Opened workspace: leaf"` row.
- `jetbrains_recent_project_observed` → `"JetBrains: leaf"` row.
- `ide_window_title_observed` → mapper returns nil (debug-only).
- vscode + Cursor + Insiders + VSCodium → appName secondary field renders correctly.

### 7.6 RelayBodyLeakageTests (privacy)

Four new sentinel walkbacks per §6. Integration-level walkback over realistic fixtures.

### 7.7 LocalAppsStore + UI feature-gate test

`IDEStorageFeatureGateTests` (mirrors P3 BrowserBookmarksFeatureGateTests): toggles persist, default both OFF, watcher start gated on toggle ON.

### 7.8 Total test surface

Estimated **~45-60 new tests** across the above suites. Baseline (post-Track-4 S4): 2012. Target post-P6: **~2055-2075**.

## 8. AppCode removal — test impact

`Packages/LeafCore/Tests/LeafCoreTests/JetBrainsStateMachineTests.swift` + adjacent S2 tests grep'd for `AppCode` string literal:

```
grep -rEn "AppCode|com.jetbrains.AppCode" Packages/LeafCore/Tests/
```

Expected hits: 1-3 (S2 baseline test cases iterating bundle IDs). Update to use a replacement IDE from the 13-bundle list (e.g. DataGrip) for test parity. No test deletion — just bundle ID substitution.

`Packages/LeafCorePrivate/Tests/` likely also references AppCode in classifier tests — same posture.

## 9. UI surface

Per contract §8 — no new top-level screens.

**Settings → Local Apps** (Track-4 S2): JetBrains bundle list shown to user gains DataGrip + RustRover + DataSpell rows, loses AppCode row. Existing toggle pattern; per-bundle ON/OFF preserved.

**Settings → System Observers** (Track-4 S3) gains "IDEs" sub-section:
- "VSCode workspace tracking" (single toggle, default OFF)
- "JetBrains recent projects" (single toggle, default OFF)

Both wired to `IDEStorageFeatureGate`. Toggle description copy locked in Stage 4 plan.

**Settings → AI Tools** (existing) — unchanged by P6 (P1 territory).

**Privacy walkback dashboard** (Track-2 D4) re-renders with four new event_kinds.

## 10. Documentation deliverables — Stage 8

### 10.1 `.claude/shared/architecture.md` Layer A clarification

Add line below Layer A AX bullet (line 56):

> Track-6 P6 extends AX windowPoll output: for vscode-family bundles (`com.microsoft.VSCode`, Cursor, Insiders, VSCodium) `AttentionEmissionPlanner` invokes a per-fork title parser and emits `vscode_active_doc_changed` (parsed `workspace_name` + `file_basename`) instead of generic attention. Parser fallback `ide_window_title_observed` (default OFF) for customized / unknown title shapes.

### 10.2 `.claude/shared/current-state.md` Track-6 closing summary

Update "Где мы" + "Следующим" sections per pattern:

- Track-6 P6 line under "Где мы" (after P5 line, mirroring Track-4 S-N entries).
- P6 acceptance smoke gate added to "Следующим".
- Track-6 closing summary once all 7 phases merge.

### 10.3 Whitepaper sync (`~/Desktop/Leaf/leaf-docs/`)

**`docs/privacy-security/what-we-dont-capture.md`** — new section:

```markdown
## IDE deep integration без plugin/extension

VSCode (включая Cursor, VSCodium, VSCode Insiders, Code OSS) и JetBrains IDE family
exposing depth of capture proportional to **plugin/extension installation**.
Per-edit telemetry, debugger state, terminal output, extension list, completion
history, AI-assistant interactions inside IDE — все эти signals достижимы только
через official plugin/extension API.

**Leaf не публикует plugin/extension в Layer A.** Capture ceiling без plugin =
window title (workspace + active file basename) + workspace open event
(FSEvents на storage directory). Plugin work — Layer D V2, отдельный track.

### Re-evaluation triggers

1. Microsoft ships official VSCode hook stream consumable by sibling processes.
2. Microsoft publishes AppleScript dictionary for `com.microsoft.VSCode`.
3. JetBrains ships official hook stream not requiring plugin install.
4. Layer D V2 track promoted to active roadmap.
5. Cursor / vscode fork ships proprietary hook stream.
```

**`docs/reference/glossary.md`** — gains:
- **"IDE surface ceiling"** — what's reachable for vscode/JetBrains without plugin (window title + workspace storage), vs what requires Layer D V2.
- **"Layer D V2"** — IDE/browser plugin track (deferred, separate from Layer A capture).

**`docs/reference/changelog.md`** — entry:

```
- **2026-05-DD HH:MM · Alex** — Track-6 P6 (IDEs Surface Cap) landed: vscode-family
  parsed active-doc + workspace-opened FSEvents, JetBrains bundle expansion (+3 IDEs, -AppCode),
  whitepaper IDE-ceiling won't-list entry + re-evaluation triggers.
```

All synced via `/sync-docs` skill in Stage 8.

## 11. Acceptance criteria — phase level

P6 is **complete** when:

1. **Code green:** all 5 xcodebuild schemes build, ~2055-2075 SPM tests pass.
2. **Parity fences hold:** `DispatchCoverageTests` covers four new event_kinds; `ActivityFeedMapperLocalOSTests` covers three (`ide_window_title_observed` skipped intentionally).
3. **Privacy walkbacks:** four new `RelayBodyLeakageTests` walkbacks pass + integration walkback covers all four payloads.
4. **Registry:** ShareEventTypeKey 152 → 156, all new entries default OFF.
5. **Classifier:** Insiders bundle ID in `.dev` Set, AppCode removed.
6. **JetBrains bundle list:** 13 entries (`-AppCode, +DataGrip, +RustRover, +DataSpell`); Fleet deferred per acceptance gate.
7. **Smoke caveat:** author has no vscode / JetBrains installed locally — Stage 7 smoke deferred to acceptance-gate session with vscode + ≥1 JetBrains IDE installed. Build + test green is hard requirement.
8. **Documentation:** `.claude/shared/architecture.md` + `current-state.md` + whitepaper sync landed in Stage 8 `docs(shared)` commit.
9. **Fleet probe placeholder** documented in acceptance-gate task list (`osascript -e 'tell application "Fleet" to get path of front document'`).
10. **Independent code review:** `superpowers:code-reviewer` subagent verdict ACCEPT or ACCEPT-WITH-NITS; any fix bundle landed.

## 12. Out-of-scope reminders (don't add)

- Plugin / extension work (Layer D V2).
- vscode `state.vscdb` SQLite reads.
- LSSharedFileList / `defaults read` probes.
- New MCP tools.
- New migrations.
- New cross-link `event_links` kinds.
- Per-product JetBrains event_kind discriminators.
- Fleet bundle ID (deferred to acceptance gate AS-probe).
- VSCode forks beyond MVP 4 (Code OSS, OpenVSCode, proprietary forks).
- Architecture.md line-56 rewrite (only coda append).

## 13. References

- Contract: `2026-05-15-track-6-existing-surface-depth-contract.md` (Track-6 invariants).
- Research: `2026-05-16-track-6-P6-ides-cap-research.md` (Stage 0 + Stage 1 verification, Q8a/b/c answers, brainstorm preview).
- Substrate predecessors:
  - Track-4 S2 `ProdJetBrainsAdapter` (JetBrains AS adapter baseline).
  - Track-1 D1 watched-folder bookmarks (security-scoped, applied to vscode workspace gate).
  - P3 `BrowserBookmarksWatcher` (FSEvents Chrome multi-profile pattern — direct fork target for both new watchers).
  - Phase 4.10.B `ActiveAppCollector` + `AttentionEmissionPlanner` (AX windowPoll substrate).
- ADR-010 walkbacks: file contents, console, debugger, terminal, search query, extension list, completion suggestion.
- Vendor sources:
  - VSCode `window.title` reference (microsoft/vscode-docs `variables-reference.md`).
  - VSCode AppleScript absence (Late Night Software forum + community consensus).
  - Cursor bundle ID (Cursor Community Forum).
  - AppCode EOL (JetBrains blog 2022-12).
  - JetBrains directory layout (intellij-support.jetbrains.com article 206544519).

---

**End of spec.** Stage 4 (writing-plans) generates atomic-per-commit step list from §3 + §4 + §7. Estimated 12-18 commits.
