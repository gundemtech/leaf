# Track 6 P6 — IDEs Surface Cap (vscode + JetBrains) · Stage 0 Research

**Phase:** Track-6 P6 (IDEs Surface Cap) — explicit ceiling-cap phase, hybrid code+doc (mirrors P7's doc shape with a small code surface).
**Stage:** 0 — Deep Research (pre-brainstorm) per contract §3.
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`.
**Date:** 2026-05-16.
**Author:** Dmitrii + Claude (research subagents: Explore on substrate; direct web/context7/probes on vendor surfaces).

This doc is the **input to brainstorm (Stage 2)**, not a plan. It maps the realistic ceiling of vscode + JetBrains capture **without an extension/plugin**, surfaces what Track-4 S2 already shipped (JetBrains baseline), flags an **architecture-doc claim that doesn't match shipped code**, and surfaces three product questions for the user before brainstorm starts.

P6 is the last sub-phase of Track-6 — closes the track. Per contract §11 (out-of-scope): vscode/JetBrains **plugin** work is Layer D V2, a separate track. P6 ratifies that boundary in the whitepaper, not just in this spec.

**Privacy contract recap (whitepaper Won't-list):** workspace name at L3 (already implicit baseline). File path at L4 (allow-list-gated). File contents / console output / debugger state / terminal output / search query / extension list — **forbidden**. URL-encoded `file://` URIs in vscode `workspace.json` are L4-L5 raw filesystem leakage — decode + redact required at parser boundary.

---

## 1. Current substrate — where we stand

Source files verified at `/Users/ddemidov/Desktop/Leaf/leaf` on `feature/track-6-P6-ides-cap` off main `9b2a53b`.

### 1.1 Track-4 S2 JetBrains baseline — already shipped

| Dimension | Current state |
|---|---|
| **File** | `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/Apple/ProdJetBrainsAdapter.swift` (86 lines) + `Packages/LeafCore/Sources/LeafCore/OS/JetBrainsStateMachine.swift` (33 lines) + `Packages/LeafCore/Sources/LeafCore/OS/JetBrainsObservation.swift`. |
| **Mechanism** | `NSAppleScript` per-tick via `AppleScriptBridge` (same actor-bound async/await wrapper Xcode adapter uses). 60s poll, 1.0s timeout. Returns `{theProject, theDoc}` array. |
| **Bundle IDs (11)** | `com.jetbrains.intellij`, `com.jetbrains.intellij.ce`, `com.jetbrains.pycharm`, `com.jetbrains.pycharm.ce`, `com.jetbrains.WebStorm`, `com.jetbrains.goland`, **`com.jetbrains.AppCode`** (discontinued — see §6.4), `com.jetbrains.CLion`, `com.jetbrains.rider`, `com.jetbrains.rubymine`, `com.jetbrains.PhpStorm`. |
| **Missing from S2 (7+ IDEs)** | `com.jetbrains.datagrip`, `com.jetbrains.rustrover`, `com.jetbrains.dataspell`, `com.jetbrains.fleet`, `com.jetbrains.aqua`, `com.jetbrains.writerside`, `com.jetbrains.mps`. (Toolbox `com.jetbrains.toolbox` is not an IDE — skip.) |
| **event_kind emitted** | `jetbrains_active_doc_changed` (single). Payload: `event_kind`, `ide_bundle_id`, `project` (optional), `doc_path` (optional). State machine emits only when `(ide, project, doc)` tuple differs from previous tick. |
| **Per-IDE state machines** | `StateMachineBox` keyed by `ideBundleID` — each IDE gets its own diff history. Pattern P6 inherits as-is. |
| **TCC posture** | Automation entitlement already paid (`NSAppleEventsUsageDescription` in LeafAgent.app). First tick post-Local-Apps toggle ON prompts per bundle ID. Denial cache 24h. |
| **ShareEventTypeKey** | `.jetbrainsActiveDocChanged` (line 185), default OFF (line 401). |
| **ActivityFeedMapper.mapLocalOS** | Whitelisted (line 442); `case "jetbrains_active_doc_changed"` at line 498 → `"JetBrains: \(basename(doc_path))"`. |
| **EventKindIcon** | `chevron.left.forwardslash.chevron.right` (line 24). |
| **Tests** | `JetBrainsStateMachineTests`, `ShareEventTypeRegistryS2Tests`, `ActivityFeedMapperLocalOSTests`, `RelayBodyLeakageTests` (sentinel walkback line 1507). |
| **Capture ceiling today** | Foreground IDE × active project × active file path. **No** per-build, per-test-run, per-VCS-action, per-debugger-state, per-scheme, per-run-config signal. Same shallow tier P5 (Zoom) inherited before P5 depth landed. |

### 1.2 VSCode + Cursor — greenfield

`grep -rEn "vscode|VSCode|microsoft.VSCode|com.todesktop|Cursor.app"` across `Packages/LeafCore/`, `Packages/LeafCorePrivate/`, `Apps/`, `Leaf/`, `LeafAgent/` returns hits **only** in two non-capture files:

- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdAppCategoryClassifier.swift:34-35` — bundle IDs in productivity category (`com.todesktop.230313mzl4w4u92` Cursor + `com.microsoft.VSCode`). Classification only — drives UI category dot color, not capture.
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Configs/FSEventsIgnoreRulesProd.swift:27` — `.vscode` listed alongside `.idea` `.vs` as ignored dot-dirs for FSEvents walks (so we don't trigger on settings.json saves inside user projects).

**Net**: zero VSCode/Cursor-specific capture code. Bundle ID `com.microsoft.VSCode` (VSCode), `com.microsoft.VSCodeInsiders` (Insiders), `com.todesktop.230313mzl4w4u92` (Cursor), and any other vscode forks (Cursor Insiders, OpenVSCode, Code OSS) reach the writer only as **L1 attention** events from `NSWorkspace.frontmostApplication` — indistinguishable from "user opened some app".

### 1.3 Accessibility API is shipped (architecture-doc claim refuted)

`.claude/shared/architecture.md` line 56 reads:

> `Accessibility API` (`AXIsProcessTrustedWithOptions`) — window title + browser URL via `AXWebArea→AXURL`, 1 prompt (drop-off risk)

This is correct as a capability claim, but the P7 research doc (§2 table row "L3 Activity verb") wrote *"No generic AX collector shipped yet in `Packages/LeafCore/Sources/LeafCore/OS/`"*. That is **wrong**. Verified shipped surface:

| File | What it does |
|---|---|
| `LeafAgent/Collectors/ActiveAppCollector.swift` (229 lines) | Frontmost-app loop. Wires `AXWindowContextProvider` (production) + `RealAXTrustChecker`. On every NSWorkspace activation OR `windowPoll` tick, reads window title via `AXUIElementCopyAttributeValue(window, kAXTitleAttribute)` and browser URL via BFS for `AXWebArea` → `kAXURLAttribute`. |
| `Packages/LeafCore/Sources/LeafCore/Insights/AttentionEmissionPlanner.swift` (`WindowContextProvider` + `AXTrustChecker` protocols) | Pure decision layer. Gated by `AttentionGranularityPolicy.maxGranularity(for: bundleID).rawValue >= L3` AND `trustChecker.isAXTrusted()`. Caps title length 200, URL length 1024 — already moat-aware. |
| `Leaf/Models/PermissionsService.swift:61,115-119` | Onboarding AX prompt via `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])`. |

So **every app whose `AttentionGranularityPolicy` resolves to L3+ already gets its window title captured today** through the attention pathway. The architecture-doc line 56 is accurate; the P7 research doc is the source of confusion (it referred to "per-app AppleScript adapter" coverage, not the shared AX pathway).

**P6 implication**: for vscode/Cursor/JetBrains, window titles **already flow into events through `ActiveAppCollector.windowPoll`** — provided their bundle IDs resolve to L3+ in `AttentionGranularityPolicy`. The "capture" question for P6 is **not** "build AX from scratch" but **"emit specific event_kinds (`vscode_active_doc_changed`, etc.) with parsed (workspace, file) fields, instead of generic `attention` events with raw title strings"**.

This is a **substantially smaller P6 surface than the prompt-level framing implied**. Stage 2 brainstorm must reconcile this with the contract §6.2 estimate ("order of ~3 entries").

### 1.4 Registry + dispatch substrate at main

- `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` — **152 cases** at line `430` (verified by `grep -c "case "`). 1 jetbrains entry. **0 vscode entries.** Default-OFF wired in `ShareEventTypeDefaults.all` per registry case.
- `Packages/LeafCore/Sources/LeafCore/DB/Schema.swift:346` — `Schema.BodyKinds` enum (FTS dispatcher targets). No IDE-related body kinds today (Track-4 S4 added 4: notes_title, zoom_meeting_name, screenshot_filename, download_filename).
- `Packages/LeafCore/Sources/LeafCore/DB/Migrations/` — **M001-M018** at main. M019-M023 reserved Track-5. M024+ reserved Track-6 (P1 used M024 partial index; P3 used M026; P4 used M027). **P6 most likely needs no new migration**; if it does, M028 next free.
- `Packages/LeafCore/Sources/LeafCore/Insights/EventKindIcon.swift:24` — `chevron.left.forwardslash.chevron.right` already mapped to `jetbrains_active_doc_changed`. P6 adds `vscode_active_doc_changed` (likely same icon, or `chevron.left.slash.chevron.right` variant for differentiation).
- `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift` — parity fences. P6 must extend.
- `Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift:1507` — `jetbrains_active_doc_changed` sentinel walkback. P6 adds vscode walkback in same shape.

---

## 2. Vendor ceiling per mechanism (2026-05)

### 2.1 VSCode AppleScript dictionary — confirmed absent

> "Visual Studio Code does not have an AppleScript dictionary file, and therefore scripting it with AppleScript will be limited. … VS Code does not have a dictionary, which means users cannot access the full range of AppleScript commands. … Since Visual Studio Code uses Electron, … automation becomes even more challenging."  
> — Late Night Software forum / makeuseof / community consensus 2024-2025 (no contradicting evidence in 2026 vendor docs).

Search-negative on `.sdef` for `com.microsoft.VSCode` and `com.todesktop.230313mzl4w4u92`. Author has no VSCode app installed locally to confirm by `find /Applications/Visual\ Studio\ Code.app -name '*.sdef'` — relying on vendor-doc + community-empirical consensus.

**Implication**: vscode/Cursor cannot mirror Xcode/JetBrains S2 pattern (read `front document.path`). Only path is **AX** + **FSEvents on storage dirs**. P6 design **must** branch on this — JetBrains uses AppleScript (extend S2), vscode/Cursor uses AX (extend `ActiveAppCollector`'s windowPoll emission with bundle-ID-specific parser).

### 2.2 VSCode window title — default + customizable

`window.title` setting controls the title bar string. Default value (vendor docs, current as of v1.108):

```
${dirty}${activeEditorShort}${separator}${rootName}${separator}${appName}
```

Substitutions (vendor docs):
- `${dirty}` — `● ` if any editor in window has unsaved changes, else empty.
- `${activeEditorShort}` — filename only (e.g. `foo.swift`).
- `${activeEditorMedium}` — workspace-relative path.
- `${activeEditorLong}` — absolute path.
- `${activeFolderShort}` / `${activeFolderMedium}` / `${activeFolderLong}` — same tier for folder.
- `${rootName}` — workspace folder name (e.g. `leaf` for `/Users/x/Desktop/Leaf/leaf`).
- `${rootPath}` — workspace folder absolute path.
- `${folderName}` / `${folderPath}` — current folder context.
- `${appName}` — `Visual Studio Code` (or fork name `Cursor`, `VSCodium`, etc.).
- `${remoteName}` — remote SSH host name, if connected.
- `${dirty}${activeEditorLanguageId}` — added v1.108 for a11y voice commands.
- `${separator}` — ` — ` or ` - ` (em-dash for VSCode stable).

**Default-format parse** (regex-friendly): `^(?<dirty>●\s+)?(?<file>[^—-]+?)\s+[—-]\s+(?<root>[^—-]+?)\s+[—-]\s+(?<app>Visual Studio Code|Cursor|VSCodium|.+)$`.

**Edge cases**:
- Single-file mode (no workspace open): title becomes `${activeEditorShort} - ${appName}` (one separator). Missing `${rootName}` segment.
- Untitled buffer: `Untitled-1 — workspace — Visual Studio Code`.
- Zen mode / focus mode: may strip activeEditor.
- User has customized `window.title` (advanced users): unknown format. Need fall-back: emit a single `event_kind: ide_window_title_observed` with raw title L3 (with ChatGPT-style allow-list redaction), no parsing.
- Multi-window: each window has own title — `AXFocusedWindow` already covers.
- Remote SSH workspace: `${rootName}` prefixed with `[SSH: host] ` — workspace is on remote, not local. P6 still emits as workspace_name = local-presented value.

### 2.3 VSCode storage — recents + per-workspace dirs (verified on author's Mac)

`~/Library/Application Support/Code/` directory tree (probed):

```
Code/
├── User/
│   ├── settings.json
│   ├── globalStorage/
│   │   ├── state.vscdb              ← SQLite, key 'history.recentlyOpenedPathsList' = JSON array
│   │   └── storage.json             ← JSON with `backupWorkspaces.folders[].folderUri` + `profileAssociations.workspaces.<uri>` map
│   ├── workspaceStorage/
│   │   ├── 0a8437ed3ad149afd08291b30ebc4af9/
│   │   │   ├── workspace.json       ← {"folder": "file:///Users/.../path"} — opening signal
│   │   │   ├── state.vscdb
│   │   │   ├── state.vscdb.backup
│   │   │   └── ms-python.python/    ← per-extension storage
│   │   └── (43 hashed dirs on probed system)
│   └── History/                     ← edit history per file (privacy hazard — full file contents past versions; forbidden)
├── CachedExtensionVSIXs/
└── (Crashpad, GPUCache, etc — Electron internals)
```

**Cursor's directory mirrors exactly** (`~/Library/Application Support/Cursor/User/...` same shape).

**Signals available via FSEvents (no FDA):**

| Event source | What FSEvents tells us | Parser yields |
|---|---|---|
| `workspaceStorage/<hash>/` directory CREATE | User opened a workspace not seen before | New `workspace.json` with `folder` URI — full filesystem path |
| `workspaceStorage/<hash>/workspace.json` UPDATE (rare) | Workspace path moved / renamed | Updated `folder` URI |
| `globalStorage/state.vscdb` UPDATE (high cadence) | Recents list mutated — opened/focused a workspace OR window state changed | Need re-read SQLite key `history.recentlyOpenedPathsList` |
| `globalStorage/storage.json` UPDATE | Profile association / backup state mutated | JSON re-read |
| `User/History/` UPDATE | Inside-file edit history (forbidden — file body content) | **Skip — Track-1 D1 walkback applies** |

`state.vscdb` is **write-locked while VSCode is running** — same hazard P3 contract called out for `History.db`. Reads while VSCode runs return SQLITE_BUSY OR stale view via `?mode=ro&nolock=1`. Forensic tooling consistently uses snapshot-copy + read.

**workspace.json is unlocked** — atomic JSON write on workspace open, plain string read works without race. **Cleanest signal.**

**Privacy hazard** — `folder` URI is URL-percent-encoded raw absolute path: `"file:///Users/ddemidov/Desktop/AgentsFarm_Projects/Task%3A_Build_a_simple_BMI_calculator_in_Python.%0AReq"`. **Full home-dir path leaks**. Without redaction this is L4-L5 content. Two parser-level walkbacks required:
1. **URL-decode** percent escapes (so we don't emit `%3A` raw).
2. **Sanitize home-dir prefix** to `~/...` — already a moat pattern in `ActivityFeedMapper.basename()` discipline.
3. **Watched-folder gate** — emit `vscode_workspace_opened` event only when the workspace folder resolves under a `WatchedFolder` (security-scoped bookmark), mirroring Track-1 D1 substrate pattern. Default: opened workspace outside any watched folder → emit `event_kind` with `workspace_name` (basename only, no path) + `outside_watched_folder=true` flag.

### 2.4 VSCode `state.vscdb` — SQLite probe results

Author probe:

```
sqlite3 ~/Library/Application\ Support/Code/User/globalStorage/state.vscdb ".tables"
→ ItemTable     cursorDiskKV

sqlite3 ... "SELECT key FROM ItemTable WHERE key LIKE '%recent%' OR key LIKE '%workspace%'"
→ chat.workspaceTransfer
→ history.recentlyOpenedPathsList

sqlite3 ... "SELECT length(value), substr(value,1,200) FROM ItemTable WHERE key='history.recentlyOpenedPathsList'"
→ 3355|{"entries":[{"folderUri":"file:///Users/ddemidov/Desktop/PortfolioDemidovDmitrii"},{"folderUri":"file:///Users/ddemidov/Desktop/SmartBulb"},...]}
```

`history.recentlyOpenedPathsList` is **the** recents list — JSON-encoded `{entries: [{folderUri, workspace, ...}, ...]}`. Mtime advances every workspace open / focus / window close. Reading correctly requires:

- (a) Snapshot-copy approach (P3 contract pattern) — `cp state.vscdb /tmp/leaf-vscode-recents-<ts>.sqlite` then read the copy. Safe but adds disk I/O.
- (b) `?mode=ro&nolock=1` URI — accept staleness/torn read risk. SQLite docs warn explicitly.
- (c) Pure FSEvents on `workspaceStorage/<hash>/` dir creations — no sqlite read needed. The dir-create event itself + JSON read of `workspace.json` (unlocked) is sufficient for "user opened workspace X" signal.

**Recommendation**: option (c) — FSEvents on `workspaceStorage/` parent dir, on CREATE event load `workspace.json` from the new hash dir, emit `vscode_workspace_opened` (or `_activated`) event. **No SQLite locking risk, no FDA, no snapshot copy.** Trade-off: misses workspace *focus* (window switch from workspace A → workspace B without opening a new one). Tactical signal value of that focus is low (already captured at L1 attention via NSWorkspace + AX window title parse).

### 2.5 Cursor (vscode fork) — same storage layout

Bundle ID `com.todesktop.230313mzl4w4u92` (community-confirmed via Cursor forum; distributed via ToDesktop platform). Storage at `~/Library/Application Support/Cursor/User/...` mirrors vscode exactly — `workspaceStorage/<hash>/workspace.json` confirmed on probed system. Window title format inherited from vscode upstream (`window.title` setting honored same way).

**P6 design implication**: vscode adapter is **parameterized by storage root + bundle ID + appName regex**. Cursor reuses same code path, swap directory + bundle ID. Same applies to other forks (VSCodium, OpenVSCode-server local, Code OSS) if/when prioritised.

### 2.6 JetBrains AppleScript — already proven (S2 baseline)

JetBrains IDEs ship a proper AppleScript suite — `name`, `path`, `front document`, `front project`. S2 `ProdJetBrainsAdapter` works for 11 bundle IDs. Mechanism known-good, no new ceiling research needed beyond bundle list expansion.

Per JetBrains support docs + community consensus 2026:

| Product | Bundle ID | Config dir | Notes |
|---|---|---|---|
| IntelliJ IDEA Ultimate | `com.jetbrains.intellij` | `~/Library/Application Support/JetBrains/IntelliJIdea<YYYY.N>/` | S2 covered. |
| IntelliJ IDEA Community | `com.jetbrains.intellij.ce` | `IdeaIC<YYYY.N>/` | S2 covered. |
| PyCharm Professional | `com.jetbrains.pycharm` | `PyCharm<YYYY.N>/` | S2 covered. |
| PyCharm Community | `com.jetbrains.pycharm.ce` | `PyCharmCE<YYYY.N>/` | S2 covered. |
| WebStorm | `com.jetbrains.WebStorm` | `WebStorm<YYYY.N>/` | S2 covered. |
| GoLand | `com.jetbrains.goland` | `GoLand<YYYY.N>/` | S2 covered. |
| **AppCode** | `com.jetbrains.AppCode` | `AppCode<YYYY.N>/` | **DISCONTINUED.** EOL 2022-12-14 sales, 2023-12-31 support. S2 line should be **removed** (P6 cleanup). |
| CLion | `com.jetbrains.CLion` | `CLion<YYYY.N>/` | S2 covered. |
| Rider | `com.jetbrains.rider` | `Rider<YYYY.N>/` | S2 covered. |
| RubyMine | `com.jetbrains.rubymine` | `RubyMine<YYYY.N>/` | S2 covered. |
| PhpStorm | `com.jetbrains.PhpStorm` | `PhpStorm<YYYY.N>/` | S2 covered. |
| **DataGrip** | `com.jetbrains.datagrip` | `DataGrip<YYYY.N>/` | **Missing from S2.** |
| **RustRover** | `com.jetbrains.rustrover` | `RustRover<YYYY.N>/` | **Missing from S2.** |
| **DataSpell** | `com.jetbrains.dataspell` | `DataSpell<YYYY.N>/` | **Missing from S2.** |
| **Fleet** | `com.jetbrains.fleet` | `Fleet<YYYY.N>/` | **Missing from S2.** AS support unverified — separate codebase from IntelliJ Platform. See §6.5. |
| **Aqua** | `com.jetbrains.aqua` | `Aqua<YYYY.N>/` | **Missing from S2.** Preview/EAP — uncertain longevity. |
| **Writerside** | `com.jetbrains.writerside` | `Writerside<YYYY.N>/` | **Missing from S2.** Not really an IDE — docs authoring tool. Skip. |
| **MPS** | `com.jetbrains.mps` | `MPS<YYYY.N>/` | **Missing from S2.** Meta Programming System — niche, very low audience. Skip. |

Version dir format: `<Product><YYYY.N>/` (no hyphen, no space). E.g. `PyCharm2025.1/`. Year is calendar release year, N is point release (1 = .0 / .1, 2 = .2 / .3 in JetBrains's quarterly cadence).

### 2.7 JetBrains recentProjects.xml — FSEvents target

Per JetBrains support article + community discussion: file at `~/Library/Application Support/JetBrains/<Product><YYYY.N>/options/recentProjects.xml`. Newer IDEs (2023.3+) renamed to `recentProjectDirectories.xml` — both filenames need watcher coverage.

XML shape (simplified):

```xml
<application>
  <component name="RecentProjectsManager">
    <option name="additionalInfo">
      <map>
        <entry key="$USER_HOME$/Desktop/Leaf/leaf">
          <value>
            <RecentProjectMetaInfo activationTimestamp="1747345678901" projectOpenTimestamp="1747000000000" ...>
              <displayName>leaf</displayName>
              <frame ... />
              ...
            </RecentProjectMetaInfo>
          </value>
        </entry>
        ...
      </map>
    </option>
  </component>
</application>
```

Same signal vscode `state.vscdb` provides (recents list with paths + activation timestamps), but here in plain XML, file is unlocked (atomic write on IDE close + on project switch), **no FDA**. FSEvents UPDATE → XML re-parse → diff against prior snapshot → emit `jetbrains_recent_project_observed` for new entry / activation timestamp delta.

**Trade-off vs AppleScript signal**: AppleScript already gives us `(project, doc_path)` on the *currently active* IDE every 60s. FSEvents on recentProjects.xml gives **historical opens + activation timestamps** — moderately richer. Per contract §3.1.5: this is **Marginal** — duplicates AS signal for current-active state, only adds historical depth (which most consumers don't query for IDE rotation). **Recommend skip** unless Q8b says otherwise.

Each JetBrains IDE writes its **own** recentProjects.xml — for FSEvents watcher, that's N paths (1 per product × 1 per year-version a user has installed). On a user with 3 IDEs × 2 versions each → 6 paths. Manageable but multi-path discovery has its own complexity (glob expand + watch loop).

### 2.8 LSSharedFileList — deprecated, replacement is FSEvents

Apple deprecated `LSSharedFileListCreate` etc in macOS 10.11+; modern recents APIs are private to apps (`NSDocument` recents lives in `~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments` opaque BinPlist, vendor-internal — anti-pattern same as P7 §2.5 ChatGPT defaults probe verdict).

**P6 doesn't need LSSharedFileList**. FSEvents path covers the same signal cleaner.

### 2.9 VSCode CLI `code --status`

`code --status` outputs JSON-ish status (running processes, GPU info, recent files). Requires:
- (a) `code` CLI installed on PATH (user-action — not guaranteed).
- (b) Shelling out from Agent — anti-pattern (Agent doesn't `exec` user-installed binaries).
- (c) Output is **diagnostic**, not state-event stream.

**Skip.** FSEvents path covers state-of-the-world without shellout.

---

## 3. TCC / sandbox audit

| Mechanism | TCC prompt? | Drop-off risk | Reliability |
|---|---|---|---|
| AX window-title via `ActiveAppCollector` for vscode/Cursor/JetBrains | **Already paid** by Phase 4.10.B onboarding step | None (already onboarded) | Universal — works for any L3+ bundle ID |
| AppleScript Automation for JetBrains (per-bundle) | Already paid in S2 onboarding step for IDEs user enables in Local Apps | First-time per-bundle prompt on tick #1 after toggle ON | Universal for IntelliJ-platform IDEs; Fleet uncertain (§6.5) |
| FSEvents on `~/Library/Application Support/Code/User/workspaceStorage/` | **No FDA, no new prompt** — `~/Library/Application Support/<vendor>/` is outside FDA umbrella (P3 §3 confirmed) | None | Universal (vscode + Cursor + any vscode fork using upstream storage layout) |
| FSEvents on `~/Library/Application Support/JetBrains/<Product><Y>/options/recentProjects.xml` | **No FDA, no new prompt** | None | Per-IDE-per-version discovery: glob + add to watcher path set |
| Read `workspace.json` (plain JSON, unlocked) | None | None | Universal |
| Read `state.vscdb` SQLite while VSCode runs | None *but* **SQLITE_BUSY** + correctness risk under live use | Locking pain (P3 contract pattern) | If snapshot-copy approach used, universal — adds I/O |
| Read `recentProjects.xml` (plain XML, atomic write on close) | None | None | Universal |
| `defaults read com.microsoft.VSCode` | None | None | Yields generic NSWindow frame + telemetry IDs — anti-pattern same as P7 §2.5. **Skip.** |

**Net**: AX path inherits TCC posture from `ActiveAppCollector`'s existing onboarding. FSEvents path inherits zero-prompt posture from P3 `BrowserBookmarksWatcher`. **No new TCC prompts.** No FDA cliff. P6 is a TCC-frictionless phase.

---

## 4. OSS reconnaissance — what others do

| Project | Mechanism for vscode | Mechanism for JetBrains | Notes |
|---|---|---|---|
| **ActivityWatch** | Plugin `aw-watcher-vscode` (Marketplace + OpenVSX). **Extension-only** — without it, falls back to `aw-watcher-window` which captures **only window title via AX**. | Plugin `aw-watcher-jetbrains-idea` for IntelliJ platform; without plugin, same AX-window-title fallback. | Same posture P6 takes: plugin = Layer D V2 (out of P6 scope); without plugin = AX title. ActivityWatch readme explicitly notes degraded fidelity without extension. |
| **WakaTime** | `vscode-wakatime` extension (Marketplace) | `jetbrains-wakatime` plugin (JetBrains Marketplace) | Extension-only — no non-extension path. |
| **RescueTime** | AppleScript-supported apps + window-title scrape fallback | Same — AS where available, title scrape for IDEs without it | Closed-source; matches our posture by construction. |
| **arbtt / Tockler / Selfspy / ulogme** | Foreground window-title scrape | Same | Lossy: no project/file structure beyond title parse. |
| **Wakatime IDE plugins** | Heartbeat with `entity` (file path), `project` (workspace), `language` (lang ID), `branch` (git) | Same payload | All extension-resident. |

**Synthesis**: every live-system productivity tracker that captures vscode/JetBrains at depth uses a plugin/extension. The non-extension path universally degrades to window-title parse + (where available) AppleScript. **P6's posture matches the live-system OSS convention.** Plugin work for vscode/JetBrains lives in Layer D V2 — confirmed by independent precedent.

Sources: github.com/ActivityWatch/aw-watcher-vscode (README), github.com/ActivityWatch/aw-watcher-window (README — AX fallback documented), github.com/wakatime/vscode-wakatime, github.com/wakatime/jetbrains-wakatime, help.rescuetime.com articles 257/57/115/45.

---

## 5. Ceiling-vs-effort table

Per contract §3.1.5. **Skip Marginal unless effort is S.**

### 5.1 VSCode + forks (vscode/Cursor/Insiders/VSCodium)

| event_kind | Mechanism | Effort | Value | Verdict |
|---|---|---|---|---|
| `vscode_active_doc_changed` | AX windowPoll: existing `ActiveAppCollector` already reads title for L3+ bundle IDs. Add bundle-ID-aware parser: regex extract `(workspace_name, file_name)` from `${dirty}${activeEditorShort} — ${rootName} — ${appName}`. Emit allow-listed `event_kind` (not raw generic attention event). | S | **Critical** | LAND. |
| `vscode_workspace_opened` | FSEvents on `workspaceStorage/<hash>/` parent dir CREATE. On new hash dir, load `workspace.json`, URL-decode + sanitize (home-dir prefix → `~`), emit basename + watched-folder-gate. | M | **Strong** | LAND if Q8b says yes (else skip — duplicates AX activation signal). |
| `cursor_active_doc_changed` | Same as vscode — adapter parameterized by bundle ID + storage root. | S | **Strong** | LAND (paramaterized — shares code with vscode). |
| `vscode_active_doc_changed` for VSCodium / OpenVSCode / Code OSS | Bundle-ID list expansion | S | Marginal | **SKIP for MVP.** Low user count. Add to "trigger re-evaluation" list (§7.4). |
| Per-extension activity / debugger / terminal state | Vendor surface requires extension | — | — | **Forbidden by Track-6 scope** — Layer D V2. |
| File-edit lifecycle (open/close/save) | Same as above | — | — | **Forbidden** — Layer D V2. |
| Git VCS state from vscode | Inferable from window-title `${activeEditorMedium}` workspace-relative path + Track-1 git polling | — | — | Composed signal — out of P6 scope, available via Track-1. |

### 5.2 JetBrains

| event_kind | Mechanism | Effort | Value | Verdict |
|---|---|---|---|---|
| `jetbrains_active_doc_changed` (existing, S2 baseline) | AppleScript per-tick `(project, doc_path)` | — | — | Already shipped. No P6 change to logic. |
| Bundle-ID list expansion: +DataGrip, RustRover, DataSpell | Single-line change in `ProdJetBrainsAdapter.targetBundleIDs` | S | **Strong** | LAND. Common IDEs in 2026 dev surface. |
| Bundle-ID list expansion: +Fleet | Same line. **BUT** Fleet AS support unverified (separate codebase). | S (if AS works) / M (if needs AX fallback) | **Strong** | LAND, gated on Q8a + on-disk probe to verify AS works (deferred to acceptance gate — user has no Fleet installed). |
| Bundle-ID **removal**: AppCode | Single-line removal (EOL Dec 2022 / 2023) | S | **Critical (cleanup)** | LAND. |
| Bundle-ID skip: Aqua + Writerside + MPS | — | — | **Marginal** | **SKIP** per §6.2 (Aqua = EAP, Writerside = not an IDE, MPS = niche). |
| `jetbrains_recent_project_observed` | FSEvents on `~/Library/Application Support/JetBrains/<Product><Y>/options/recentProjects[Directories].xml` per IDE-version, parse XML diff | M | **Marginal** | **SKIP** unless Q8b says yes — duplicates AppleScript active-state signal. |
| Per-IDE event_kind discriminators (`pycharm_*`, `webstorm_*`, etc.) | Refactor S2 single-kind to per-bundle-ID | M | **Marginal** | **SKIP** — `ide_bundle_id` payload field already discriminates per-IDE without registry bloat. Consumer (Phase 4.9) filters on payload. |
| Per-edit / debugger / VCS state | Plugin required | — | — | **Forbidden** — Layer D V2. |

### 5.3 Generic IDE substrate

| event_kind | Mechanism | Effort | Value | Verdict |
|---|---|---|---|---|
| `ide_window_title_observed` (catch-all) | Bundle ID outside vscode/Cursor/JetBrains family but classified as IDE-category in `ProdAppCategoryClassifier` | M | Marginal | **SKIP** — too generic; relies on classifier curation. |

### 5.4 Net P6 event_kind addition target

- **+1 net new**: `vscode_active_doc_changed` (covers vscode + Cursor + Insiders via param).
- **+1 net new optional** (gated on Q8b): `vscode_workspace_opened` (FSEvents).
- **0 new for JetBrains** (extension is line-item additions to existing adapter — no new event_kind, no new ShareEventTypeKey).

Contract §6.2 estimate: "order of ~3 entries" for P6. Reality: **1-2 entries**. Within tolerance.

ShareEventTypeKey baseline 152 → 153-154 on P6 isolated branch. Default OFF for new entries per ADR-020.

---

## 6. Anti-patterns / carry-overs

### 6.1 Architecture-doc line 56 — accurate, but cross-doc confusion

`.claude/shared/architecture.md` Layer A bullet for AX is correct. P7 research doc (§2 table row "L3 Activity verb") wrote "No generic AX collector shipped yet" — that's wrong; the collector exists in `ActiveAppCollector.swift` + `AttentionEmissionPlanner.swift`. **P6 spec must NOT repeat that mistake** — vscode capture builds on shipped AX, not on hypothetical future collector.

**Action**: P6 ship task includes a one-line correction to P7 research doc footnote OR a clarification line in architecture.md about "the shipped AX surface is `ActiveAppCollector.windowPoll` — emits generic attention events with title strings; P6 adds bundle-ID-aware parsing layer for vscode kinds without changing the AX read."

### 6.2 Track-3/4 patterns to inherit

- **State machine per-IDE** (Box pattern from `JetBrainsStateMachine` + `ChromeStateMachine`) — required for vscode multi-bundle-ID (vscode + Cursor + Insiders) so per-bundle prev-state doesn't collide.
- **L4 sensitivity walkback** — `RelayBodyLeakageTests` sentinel walkback per new event_kind. Inject `LEAKED_SENTINEL_VSCODE_P6` into forbidden payload positions (file_body, file_contents, console_output, debugger_state, extension_list, terminal_text, search_query, completion_suggestion) and assert no leak. Mirror `RelayBodyLeakageTests:1507` shape exactly.
- **DispatchCoverageTests parity fence** — extend `trackFourLocalOSKinds` + `mapLocalOS` + `EventKindIcon` triple. Pattern locked since Track-4 S4 fix-bundle.
- **ADR-010 walkback at parser boundary** — vscode `workspace.json` URL-decode + home-dir prefix sanitize **before** RawEvent emission, not in mapper. P3 BookmarkCountDeriver pattern.
- **Watched-folder gate for path-bearing events** — Track-1 D1 substrate. `vscode_workspace_opened` carries full path only when resolved workspace is under a `WatchedFolder` security-scoped bookmark. Otherwise emit only `workspace_name = basename` + `outside_watched_folder=true`.

### 6.3 Cross-step concern — single state machine vs per-bundle?

S2 `ProdJetBrainsAdapter` uses `StateMachineBox` keyed by `ideBundleID` (one machine per IDE). vscode + Cursor are technically separate apps with separate workspaces. Two reasonable choices:
- (a) **Single `VSCodeStateMachine`** keyed by `(bundleID, workspace)`. Simpler.
- (b) **Per-bundle Box pattern** mirroring JetBrains. Consistent with S2 architecture.

Lean (b) — pattern consistency wins. Decided in Stage 2 brainstorm.

### 6.4 AppCode in S2 baseline is a stale entry — remove

`ProdJetBrainsAdapter.targetBundleIDs[7]` = `"com.jetbrains.AppCode"`. EOL Dec 2022 (sales) / Dec 2023 (support). Author's Mac has no AppCode installed. **P6 includes a one-line removal in the bundle list** (sub-step of the JetBrains expansion task). Risk: any S2 baseline test that asserts AppCode in the list — verify + update. Greppable in `Packages/LeafCore/Tests/LeafCoreTests/JetBrainsStateMachineTests.swift` and adjacent S2 tests.

### 6.5 Fleet uncertainty

Fleet (`com.jetbrains.fleet`) is JetBrains's next-gen lightweight IDE, separate codebase from IntelliJ Platform. Whether it ships an AppleScript dictionary the same way is **unverified** — author has no Fleet installed; vendor docs don't confirm; community references inconsistent. Two outcomes:
- AS dictionary works → fold into ProdJetBrainsAdapter bundle list. 1-line change.
- AS dictionary missing → Fleet needs AX-window-title-parse like vscode. Different code path.

**Recommendation**: defer Fleet to **acceptance-gate session** — author/team-mate installs Fleet, probes `osascript -e 'tell application "Fleet" to get path of front document'`. If yes → 1-line append. If no → list as v1.1 follow-up. **P6 MVP does not include Fleet.**

### 6.6 vscode/Cursor/JetBrains bundle classification

`ProdAppCategoryClassifier` already classifies these as "productivity". Verify `AttentionGranularityPolicy` maps the productivity category to L3+ (so AX windowPoll fires). Otherwise vscode AX path is null — P6 must add L3 entry for these bundles **or** ratify the classifier-to-policy mapping. **Discovery item** for Stage 1.

### 6.7 URL-encoded path leak surface

`workspace.json.folder` URI is **raw L4-L5 content**. Without `URLDecode + homeDir prefix sanitize`, even basename-derivation in mapper leaks through (URL-encoded `%2F` parses to `/`; nested home-dir paths reveal user identity). P6 parser must URL-decode + sanitize **before** any payload assembly. Add `LEAKED_SENTINEL_VSCODE_P6_PATH` to `RelayBodyLeakageTests` for this specific walkback (e.g. inject `~/Desktop/SECRET-VSCODE-PATH-MARKER` as folder URI, assert sanitized output drops it).

### 6.8 Anti-patterns avoided (don't repeat)

- **No SQLite read while app runs** — Track-3 D2 / P3 §2.3 pattern. `state.vscdb` is locking-hostile; we route around via FSEvents on `workspaceStorage/` instead.
- **No vendor-internal store parsing** — P7 §2.4/2.5 precedent. We DO parse `workspace.json` (documented public format, plain JSON), we DON'T parse `state.vscdb` ItemTable keyspace.
- **No shellout to `code --status`** — Agent doesn't exec user-installed binaries.
- **No History.db reads** — Track-1 D1 / D2 walkback applies to `User/History/` per-file edit history (full content past versions).
- **No CFAbsoluteTime / Cocoa epoch confusion** — recents JSON in `workspaceStorage/<hash>` is unix-ms or ISO-8601 string; pin in parser.
- **No raw `${separator}` regex assumption** — VSCode default is em-dash `—`, but user-customized title may use any string. Fall back to `event_kind: ide_window_title_observed` + raw title (L3, ChatGPT-style allow-list default OFF) if regex fails to match expected shape.

---

## 7. Documented ceiling — main P6 deliverable

P6 is **explicit ceiling-cap phase** (contract §11). Code lands a small surface (1-2 event_kinds + JetBrains bundle expansion). The bigger deliverable is the **whitepaper won't-list entry** and **architecture clarification** — mirrors P7 pattern exactly.

### 7.1 Whitepaper won't-list addition

Target file: `~/Desktop/Leaf/leaf-docs/docs/privacy-security/what-we-dont-capture.md` (assumed path; verify in Stage 8 sync). P7 added section "AI co-pilot surfaces без per-event API". P6 adds **adjacent section** OR extends it:

```markdown
## IDE deep integration без plugin/extension

VSCode (включая Cursor, VSCodium, Code OSS), JetBrains IDE family и аналогичные
редакторы exposing depth of capture proportional to **plugin installation**.
Per-edit telemetry, debugger state, terminal output, extension list, completion
history, AI-assistant interactions inside IDE — все эти signals достижимы только
через official plugin/extension API.

**Leaf не публикует plugin/extension в Layer A.** Capture ceiling без plugin =
window title (workspace + active file basename) + workspace open event
(FSEvents on storage dir). Plugin work — Layer D V2, отдельный track.

Re-evaluation triggers:
- Vendor (Microsoft / JetBrains) ships first-party hook stream parallel to
  Claude Code's local hooks SDK.
- Either vendor ships AppleScript dictionary (vscode currently has none).
- Plugin track promoted to active roadmap.
```

### 7.2 Architecture.md update

Layer A bullet for AX (line 56) reads correctly. Add follow-on context line: P6 emits `vscode_active_doc_changed` as a parsed-payload extension of the AX windowPoll surface — not new infrastructure. Keep concise: 1-2 lines max in `.claude/shared/architecture.md`.

### 7.3 Glossary entries

`.claude/shared/glossary.md` (or whitepaper glossary) gains:
- **"IDE surface ceiling"** — what's reachable for vscode/JetBrains without plugin (window title + workspace storage), vs what requires Layer D V2 (per-edit / debugger / etc).
- **"Layer D V2"** — IDE/browser plugin track (deferred, separate from Layer A capture).

### 7.4 Re-evaluation trigger list (for the spec, lift verbatim to whitepaper)

The ceiling is not a forever vow. Reopen P6 follow-up phase when any of:

1. **Microsoft** ships official VSCode hook stream consumable by sibling processes (parallel to Claude Code hooks SDK or LSP server-side telemetry).
2. **Microsoft** publishes AppleScript dictionary (`.sdef`) for `com.microsoft.VSCode` (vendor has never done so for Electron apps — low probability).
3. **JetBrains** ships official hook stream not requiring plugin install (e.g. via JB Toolbox), parallel to vscode's hypothetical hook stream.
4. **Layer D V2 track promoted** — whichever sub-phase under it ships first (vscode extension OR JetBrains plugin OR Chrome extension), the corresponding Track-6 won't-list entry retires.
5. **Cursor or other vscode fork** ships proprietary hook stream OpenAI's Codex CLI-style. Triggers extension to vscode-family adapter only (other forks).

When any trigger fires → reopen Track-6 follow-up phase with fresh Stage 0. Trigger list carries verbatim to whitepaper so future maintainers don't re-litigate.

---

## 8. Phase-level questions for user (pre-brainstorm)

P6 surfaces three product questions. Stage 2 brainstorm blocks on answers.

### Q8a — JetBrains IDE coverage scope

**Recommendation**: Subset MVP for P6, not all 18. Specifically:

- **Keep all 11 existing S2 bundle IDs** (no regressions). **Except**:
  - **Remove `com.jetbrains.AppCode`** (discontinued Dec 2022 / Dec 2023 EOL — §6.4).
- **Add 3 high-traffic IDEs**: DataGrip, RustRover, DataSpell.
- **Defer Fleet** to acceptance-gate AS-probe (§6.5).
- **Skip** Aqua (EAP), Writerside (docs tool, not IDE), MPS (niche).

**Net**: 11 - 1 + 3 = **13 IDEs** in P6 MVP. Fleet enters as v1.1 follow-up if AS works.

**Question**: agree with the subset or want different scope?

### Q8b — Recent Files FSEvents — track or skip?

§2.7 / §5.1 / §5.2 marked `vscode_workspace_opened` (FSEvents on `workspaceStorage/`) + `jetbrains_recent_project_observed` (FSEvents on recentProjects.xml) as **Marginal** — duplicates AX active-state signal.

But there's a sub-case where FSEvents is **not** marginal: **historical workspace activation pattern** (which projects user worked on this week, even if not in current foreground). AX windowPoll only sees foreground; FSEvents on storage paths sees all opens including background-window switches and just-closed-windows.

**Recommendation**: **Track for vscode** (FSEvents on `workspaceStorage/` parent dir CREATE → emit `vscode_workspace_opened` with watched-folder-gate). **Skip for JetBrains** — AS active-doc signal already covers, and per-IDE-per-version recentProjects.xml multipath discovery adds complexity for marginal additional signal.

Net: +1 event_kind (`vscode_workspace_opened`), no JetBrains FSEvents wiring.

**Question**: agree, or skip both, or track both?

### Q8c — AX title parser — shared or per-product?

For vscode + Cursor + Insiders + VSCodium + (potentially) Fleet, window title format is **vendor-specific but parameterized by appName regex**:

- vscode: `${dirty}${activeEditorShort} — ${rootName} — Visual Studio Code`
- Cursor: `${dirty}${activeEditorShort} — ${rootName} — Cursor`
- Insiders: `... — Visual Studio Code - Insiders`
- VSCodium: `... — VSCodium`
- (Fleet if AS missing): `${rootName} — ${activeFile} | Fleet` (vendor-specific shape unverified)

For JetBrains (S2 baseline already): no AX parse — AS gives structured `(project, doc_path)`.

**Recommendation**: **One shared `VSCodeFamilyTitleParser`** with parameterized appName regex set. Falls back to `event_kind: ide_window_title_observed` (single generic kind) if regex fails to match any known fork's shape — allows graceful degradation when user customizes `window.title` or when a new fork ships unrecognized format.

Per-product parser would mean N similar regex paths with no real divergence — anti-DRY. **One shared parser.**

**Question**: agree shared, or prefer per-fork files for future divergence?

---

## 9. Stage 0 acceptance — what brainstorm uses from this

After Q8a-c answered:

1. **Spec scope** narrows to: extend `ActiveAppCollector` (or adjacent layer) with `VSCodeFamilyTitleParser` emitting `vscode_active_doc_changed`; extend `ProdJetBrainsAdapter` bundle list (remove AppCode, add 3 IDEs); optionally add FSEvents watcher emitting `vscode_workspace_opened`.
2. **Schema additions**: 0 migrations (or M028 only if a sub-decision in brainstorm requires it — unlikely).
3. **Registry**: +1 or +2 entries, default OFF.
4. **MCP tools**: 0 (contract §4 default).
5. **Cross-link substrate**: 0 (no Track-1 link kinds).
6. **Whitepaper sync**: §7.1-7.4 above, mirroring P7's won't-list addition.
7. **Tests**: 1-2 new RelayBodyLeakageTests walkbacks, parity-fence extension in DispatchCoverageTests, parser unit tests for vscode title regex (default + 4 customization variants + Insiders + Cursor + VSCodium + URL-encoded folder URI).

Estimated commit count for plan stage: **6-10 atomic commits** (small phase by code volume; majority of work is research + whitepaper sync — already done here).

---

## 10. Sources

- VSCode `window.title` reference — [microsoft/vscode-docs variables-reference.md](https://github.com/microsoft/vscode-docs/blob/main/docs/reference/variables-reference.md), release-notes v1.10, v1.33, v1.108.
- VSCode AppleScript absence confirmation — Late Night Software forum thread "How to minimize VS Code", makeuseof article "VS Code as Scripting Editor", community consensus across multiple sources.
- Cursor bundle ID — [Cursor Community Forum: Bundle Identifier](https://forum.cursor.com/t/cursor-bundle-identifier/779).
- AppCode EOL — [JetBrains AppCode blog 2022-12 EOL announcement](https://blog.jetbrains.com/appcode/2022/12/appcode-2022-3-release-and-end-of-sales-and-support/).
- JetBrains directory layout — [JetBrains Support: Directories used by the IDE](https://intellij-support.jetbrains.com/hc/en-us/articles/206544519) ("Directories used by the IDE to store settings, caches, plugins and logs").
- recentProjects.xml location — JetBrains Community discussions + Open recent project guide ([jetbrains.com/guide/java/tutorials/import-project/open-recent-project](https://www.jetbrains.com/guide/java/tutorials/import-project/open-recent-project/)).
- ActivityWatch posture — [aw-watcher-vscode](https://github.com/ActivityWatch/aw-watcher-vscode) + [aw-watcher-window](https://github.com/ActivityWatch/aw-watcher-window) READMEs.
- WakaTime IDE plugins — github.com/wakatime/vscode-wakatime, github.com/wakatime/jetbrains-wakatime.
- On-disk probes (2026-05-16) — author's Mac filesystem:
  - `~/Library/Application Support/Code/User/workspaceStorage/<43 hashed dirs>/workspace.json`
  - `~/Library/Application Support/Code/User/globalStorage/{state.vscdb,storage.json}`
  - `~/Library/Application Support/Cursor/User/workspaceStorage/<dirs>/workspace.json`
  - `~/Library/Application Support/JetBrains/` — **empty/absent** on this Mac (no JetBrains products installed) → smoke gate for JetBrains-side P6 changes requires user to install ≥1 JetBrains IDE before acceptance.

---

**End of Stage 0.** Stage 1 (Discovery) gated on Q8a/Q8b/Q8c answers.
