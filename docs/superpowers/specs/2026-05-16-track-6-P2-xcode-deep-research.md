# Track 6 P2 — Xcode Deep · Stage 0 Research

**Stage:** Stage 0 (Deep Research) — companion to upcoming phase spec
**Contract:** `2026-05-15-track-6-existing-surface-depth-contract.md`
**Date:** 2026-05-16
**Author:** Dmitrii + Claude (research subagents: Explore + WebSearch/WebFetch)

This doc is the **input to brainstorm (Stage 2)**, not a plan. It maps the realistic ceiling of Xcode capture on macOS, surfaces the deltas between substrate and ceiling, and ends with 4 product questions for the user to answer before brainstorm starts.

---

## 1. Current substrate (where we stand)

Source: `Packages/LeafCore/Sources/LeafCore/OS/XcodeStateMachine.swift`, `Packages/LeafCorePrivate/Prod/Collectors/Apple/ProdXcodeAdapter.swift`, `Packages/LeafCore/Sources/LeafCore/OS/AppleScriptAdapter*.swift`, `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift`, `Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift`.

Track-4 S2 (AppleScript Surface, landed 2026-05-12) is the floor.

| Dimension | Current state |
|---|---|
| **Capture mechanism** | AppleScript only. 60s tick poll, 1s script timeout. No FSEvents on DerivedData. No xcresult parsing. |
| **event_kinds emitted** | **2 total:** `xcode_active_doc_changed`, `xcode_build_state_changed`. |
| **Payload `xcode_active_doc_changed`** | `event_kind, doc_path?, project?, scheme?`. Doc_path is full POSIX path; project = workspace document name; scheme = active scheme name. All optional — emitted if probe succeeded. |
| **Payload `xcode_build_state_changed`** | `event_kind, build_state` (raw enum string). State machine flips → emit. Built off AppleScript `last scheme action result.status`. |
| **State machine** | `XcodeStateMachine` (public LeafCore/OS) — pure transition detector. Emits up to 2 RawEvents per tick: doc-change (path/project/scheme tuple diff) and build-state flip. First observation emits both. Idempotent across identical observations. |
| **AppleScript dictionary used** | `front workspace document` → `path`, `name`, `active scheme.name`, `last scheme action result.status`. |
| **TCC posture** | `AppleScriptPermissionStore` — `notRequested → granted | denied(ms) | appNotInstalled | unavailable`. 24h denial backoff. Per-bundleID UserDefaults keys `appleScript.permission.state.com.apple.dt.Xcode` + denial timestamp. |
| **Feature gate** | `LocalAppsStore.isEnabled("com.apple.dt.Xcode")` → defaults OFF. Toggle in Settings → Local Apps. |
| **ShareEventTypeKey entries** | 2: `.xcodeActiveDocChanged` + `.xcodeBuildStateChanged`. Both `defaultEnabled = false` in `ShareEventTypeDefaults`. |
| **ActivityFeedMapper** | `case "xcode_active_doc_changed"` → `"Xcode: <basename(doc_path)>"`. Build-state not in feed mapper (substrate-only). |
| **Aggregations** | None Xcode-specific. Generic attention rollup includes `bundleID = com.apple.dt.Xcode`. |
| **Tests** | `XcodeStateMachineTests.swift` (transition coverage); `RelayBodyLeakageTests.testEventBodyDoesNotLeakIntoPresenceState_Xcode` (1 sentinel walkback fence). |

**Gaps vs Track-6 contract §2:** build started/finished timing + duration; test run started/finished + pass/fail counts; run destination / target / config flips; build error/warning counts. None captured today.

---

## 2. Vendor ceiling — Xcode 16+ on macOS 15+

Source: live probing on author's Mac, Apple developer docs, Xcode AppleScript Sdef (live `osascript`), `xcrun xcresulttool` man pages, Xcode 16 release notes.

### 2.1 AppleScript dictionary — depth available

Live probe on author's Mac (Xcode 16, Apple Silicon):

```
tell application "Xcode" → workspace document properties:
  path                    → "/Users/ddemidov/Desktop/Leaf/leaf/Leaf.xcodeproj"
  name                    → "Leaf.xcodeproj"
  loaded                  → true
  modified                → false
  active scheme           → scheme "Leaf"
    .name                 → "Leaf"
  active run destination  → run destination | missing value
    .name                 → device/sim name when set
  last scheme action result → action result | missing value
    .status               → enum: not yet started | running | succeeded | failed | cancelled
    .build log            → build log object (NEVER read — body forbidden, ADR-010)
  projects                → list of project objects
    .name, .id            → project name + UUID
    .targets              → list of target objects
      .name, .id          → target name + UUID
  schemes                 → list of scheme objects
```

**Per-tick achievable (read-only):**
- `scheme.name` (already captured)
- `active run destination.name` — flips on simulator/device switch (NEW)
- `last scheme action result.status` (already captured via build_state_changed)
- `last scheme action result.error count` / `warning count` properties **DO exist in dict** but unreliable per OSS chatter — vendor-survey did not confirm population on Xcode 16. Fallback: xcresult parsing.

**NOT achievable via AppleScript (vendor surface):**
- Per-target compile-error breakdown
- Test pass/fail counts
- Compile duration
- Diagnostic source locations

### 2.2 DerivedData + xcresult — structured build/test artefacts

Source: live filesystem probe on author's Mac. Path: `~/Library/Developer/Xcode/DerivedData/<ProjectName>-<28-char-hash>/`.

**Per-project structure (live):**
```
Leaf-dqqvphprbvvfkxabaugkymigacwk/
├── info.plist            ← WorkspacePath + LastAccessedDate
├── Logs/
│   ├── Build/<UUID>.xcactivitylog     ← gzipped SLF binary (build records)
│   ├── Build/LogStoreManifest.plist   ← UUID → metadata map (logFormatVersion + logs dict)
│   ├── Test/<UUID>.xcresult/          ← bundle: Info.plist + Data/data.0~* + refs.0~*
│   ├── Test/LogStoreManifest.plist
│   ├── Launch/<UUID>.xcresult/
│   └── Launch/LogStoreManifest.plist
├── Build/Intermediates.noindex/
└── Index.noindex/                     ← do NOT touch — Sandbox-protected on some configs
```

**Multiple DerivedData hashes per project are normal** — Xcode mints a fresh hash when the workspace path or the source command differs. Author's Mac has 3 active hashes for Leaf (separate Xcode/CLI/agent variants). Aggregation key is `workspacePath` from `info.plist`, not the hash.

### 2.3 xcresulttool — structured JSON CLI (Critical mechanism)

Live test on author's Mac (`xcresulttool version 24408, schema 0.1.0, legacy commands format 3.56`):

```bash
xcrun xcresulttool get build-results summary --path <xcresult>
```

Returns structured JSON:
```json
{
  "analyzerWarningCount": 0,
  "destination": { "platform": "macOS", "architecture": "arm64",
                   "deviceName": "My Mac", "modelName": "MacBook Air",
                   "osVersion": "26.5" },
  "endTime": 1778932868.319,
  "errorCount": 4,
  "errors": [{ "issueType": "Swift Compiler Error",
               "message": "Cannot find 'DBDomainAllowListReader' in scope",
               "sourceURL": "file://...#StartingLineNumber=427",
               "targetName": "LeafAgent" }],
  "startTime": ..., "warningCount": ...
}
```

**Privacy walkback per ADR-010 / contract §7:** `errorCount`, `warningCount`, `analyzerWarningCount`, `targetName`, `startTime`, `endTime`, `destination.platform` ✅ allowed. `errors[].message` (full compiler error text) + `errors[].sourceURL` ❌ forbidden — parser strips before emit. `destination.deviceName` is the user's machine name (e.g. "My Mac" / "Dmitrii's MacBook Air") — **bucketed** before emit (`macos | ios_simulator | ios_device | tv | watch | vision`), raw `deviceName` never stored.

For tests: `xcresulttool get test-results summary` returns analogous schema (`passedTests`, `failedTests`, `skippedTests`, `expectedFailures`, `totalTestCount`, per-target duration). Same walkback discipline — test names (which are user-authored identifiers, sometimes describing failure cause) are **bucketed counts only**, never the test name string.

**Schema stability risk:** Xcode 16 marks the command-set as "legacy commands format". Apple is migrating to a new `xcresulttool` v3 command surface (`get build-results --legacy=false`). Both currently work; legacy may be removed in Xcode 27. Parser must pin to `--legacy` explicitly and feature-detect new schema; degrade gracefully if Apple removes legacy entirely.

### 2.4 xcactivitylog — gzipped SLF binary (Marginal mechanism)

Source: XCLogParser docs (MobileNativeFoundation), Polidea/davidahouse historical writeups.

`.xcactivitylog` files are gzip-compressed SLF (Structured Logging Format). Format version bumps per Xcode major:
- v10 — Xcode 10..14
- v11 — Xcode 15.3+ (added attachment arrays)
- v12 — Xcode 26.2+ (added integer field before subtitle)

Parser must:
1. Gzip-decompress
2. Decode 7+ SLF token types
3. Match property positional order via class-dump reverse engineering of internal Xcode types
4. Conditionally branch on version (3 variants today, 4th likely by Xcode 27)

XCLogParser (MNF fork, maintained) does this in ~2-3k LOC across the parser + class definitions. Minimal subset in pure Swift would still exceed ~500 LOC for the parts we need (build duration + target list + error count). High maintenance burden across Xcode version bumps.

**Verdict:** for plain `Cmd+B` builds that produce *only* xcactivitylog (no xcresult), error count from xcactivitylog parse is the only way. For builds triggered as part of Run / Debug / Test (95%+ of meaningful build endpoints), xcresult bundles already capture all the same data via stable structured JSON. **Recommend: skip xcactivitylog parsing in P2.** Accept the gap on pure-build endpoints; emit build start/finish/state via the AppleScript path (already in S2) and enrich with errorCount/warningCount only when a sibling xcresult appears.

### 2.5 FSEvents on DerivedData — viability

`~/Library/Developer/Xcode/DerivedData/` is a **regular user-home subdirectory** — no TCC FDA gate, no Sandbox restriction for an unsandboxed LaunchAgent. Live `xcrun xcresulttool` on author's Mac succeeded **without** any prompt.

FSEvents on `~/Library/Developer/Xcode/DerivedData/*/Logs/{Build,Test,Launch}/` gives:
- New `.xcresult` bundle directory created → test/run finished signal (xcresult only written after run completes)
- New `.xcactivitylog` file → build finished signal (same — only written on completion)
- `LogStoreManifest.plist` mutation → secondary signal, sometimes useful for de-dupe

**Cold-start race:** on Agent restart, last-N existing xcresult bundles are pre-existing — we must NOT replay them as fresh `xcode_test_run_finished` events. Mitigation: store `last_seen_xcresult_mtime` cursor per DerivedData hash, only emit for bundles with `dateCreated > cursor`. Mirror Track-3 D1 polling-cursor pattern.

**Per-project hash multiplicity:** watch `~/Library/Developer/Xcode/DerivedData/*` with a single FSEvents subscription rather than per-project. Discovery: walk on Agent start + on `kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir` at depth 1 to pick up new project additions.

### 2.6 Run destination + scheme — already in dictionary

Already in §2.1 — AppleScript exposes both per-tick. No new mechanism needed beyond extending current adapter.

---

## 3. OSS reconnaissance

Source: WebSearch / live repo inspection.

### 3.1 XCResultKit (davidahouse, v1.2.2 Feb 2025, 6yr maintained)

Friendly Swift wrapper over `xcrun xcresulttool` and `xccov`. Used by FastLane scan, danger plugins, danger-xcode-summary. Shells out to xcresulttool; no native binary format parsing. Pattern: `let file = XCResultFile(url:)` → typed accessors for test result records / activity logs / coverage data.

**Takeaway:** validates xcresulttool as the de-facto stable parsing surface. We won't ship XCResultKit as a dependency (adds 6k LOC + maintenance surface) — instead, we wrap `xcrun xcresulttool` directly with a thin parser scoped to the 6 fields we want.

### 3.2 XCLogParser (MobileNativeFoundation, Spotify origin)

Production-grade xcactivitylog parser. Confirms format complexity + version fragility (§2.4). Spotify uses for build-profiling dashboards. **Not a model for us** — over-scoped for L4 metadata-only capture.

### 3.3 Wakatime macos-wakatime

Uses AX (`AXUIElementCopyAttributeValue` on Xcode windows) for active file path. **Does NOT** parse DerivedData / xcresult / xcactivitylog. Ceiling: file-name only. We exceed this by going xcresult.

### 3.4 ActivityWatch

No first-party Xcode watcher in the official org. Community watchers do app-level + window-title attribution (parity with our S2 floor). No DerivedData watcher in OSS recon.

### 3.5 FastLane `scan` + Bazel `rules_xcodeproj`

Both shell out to `xcodebuild` and parse the resulting xcresult via `xcresulttool` / XCResultKit. Same pattern we propose.

---

## 4. TCC + sandbox audit

| Action | TCC prompt | Sandbox issue |
|---|---|---|
| FSEvents on `~/Library/Developer/Xcode/DerivedData/*` | **None** (user-home subdir, no FDA bracket) | None for unsandboxed LaunchAgent |
| Read `<bundle>.xcresult/Info.plist` | None | None |
| `xcrun xcresulttool get build-results summary` | None | None — Xcode CLI tools run in user context |
| Read `<bundle>.xcactivitylog` (if pursued — §2.4 says skip) | None | None |
| AppleScript `tell application "Xcode"` | **Existing prompt** (already shown for active_doc_changed) — no new prompt for additional scheme/run-destination fields | None |

**Hardened-runtime / notarization:** Agent calls `Process()` to spawn `/usr/bin/xcrun` → `xcresulttool`. Hardened runtime + entitlement audit needed: spawning child processes is permitted by default unless we add `com.apple.security.cs.disable-executable-page-protection`-style restrictions. Current Agent entitlements (see `LeafAgent/LeafAgent.entitlements`) — likely no extra entitlement needed; verify in Stage 1 discovery.

**No FDA prompt for DerivedData reads.** Confirmed live on author's Mac with Hardened Runtime ON.

---

## 5. Ceiling-vs-effort table

Per contract §3.1 step 5. Effort S/M/L; value Critical/Strong/Marginal. Skip Marginal unless effort is S.

| Signal | Mechanism | Effort | Value | Verdict |
|---|---|---|---|---|
| `xcode_build_started` | AppleScript status: `idle → running` (already in `build_state_changed`) | S | Critical | **Split out as first-class event_kind** (was implicit in build_state) |
| `xcode_build_finished` | AppleScript status: `running → succeeded/failed/cancelled` + xcresult enrichment if sibling appears within 5s | M | Critical | **Land** — payload: `status, durationMs, errorCount?, warningCount?, schemeName, configurationName, targetName?` |
| `xcode_test_run_started` | FSEvents `Logs/Test/<UUID>.xcresult` dir created | S | Strong | **Land** — payload: `schemeName, runDestinationBucket` |
| `xcode_test_run_finished` | FSEvents on `Logs/Test/<UUID>.xcresult/Info.plist` write + `xcresulttool get test-results summary` | M | Critical | **Land** — payload: `passedCount, failedCount, skippedCount, totalCount, durationMs, schemeName, runDestinationBucket` |
| `xcode_scheme_changed` | AppleScript `active scheme.name` diff (split from `active_doc_changed` payload) | S | Strong | **Land** — payload: `schemeName, projectName` |
| `xcode_run_destination_changed` | AppleScript `active run destination.name` diff + bucket | S | Strong | **Land** — payload: `runDestinationBucket` (raw `deviceName` NEVER stored) |
| Build error/warning count enrichment | `xcrun xcresulttool get build-results summary --legacy` on Run/Test xcresult | M | Strong | **Land as enrichment on `build_finished`** |
| `xcode_target_changed` | AppleScript `active scheme.buildable references` (target list) diff | M | Marginal | **Skip** — most users don't switch target manually; scheme covers 95% |
| `xcode_configuration_changed` | AppleScript `last scheme action result.action info.configuration name` diff | S | Marginal | **Defer to v1.1** — Debug→Release flip is rare; effort S but value Marginal |
| `xcode_clean_performed` | FSEvents on `Build/Products` mass-delete or `xcactivitylog` action=clean | M | Marginal | **Skip** — not predictive of user state; can derive from build_started lacking prior cached output |
| Pure-build error counts (Cmd+B without Run) | xcactivitylog binary parse | L | Strong | **Skip** — see §2.4; format fragility >> value; Run/Test covers 95% of meaningful build endpoints |
| `xcode_breakpoint_hit` | AppleScript not exposed; LLDB Mach port — out of scope | L | Marginal | **Skip permanent — debugger state forbidden per ADR-010** |
| Per-file compile duration | xcactivitylog parse | L | Marginal | **Skip** — same as pure-build; format risk |
| Indexing in progress / SourceKit state | Internal Xcode AX or undocumented IPC | L | Marginal | **Skip** — undocumented; brittle |

**Net: 6 new event_kinds.** Aligns with contract §6.2 P2 estimate ("~6 entries: build / test / scheme / target / config / clean"). Our 6 substitute target/config/clean (Marginal) with build_started + test_run_started (Strong). `build_state_changed` from S2 is **deprecated** at the registry level — its semantic is fully covered by `build_started + build_finished`. Plan: keep `build_state_changed` ShareEventTypeKey in registry for back-compat (no-removal append-only discipline per contract §6.2), but stop emitting from `XcodeStateMachine` — the new event_kinds replace it. Migration deprecation note in spec.

Wait — re-reading contract §2.5 ("Per-flavour parsers tolerate edge cases… same posture as Track-3 D1/D2/D3") and §4 ("the phase extends — not replaces — that collector. The shallow event_kind stays; new event_kinds layer on") — **`build_state_changed` stays.** Final shape:

- KEEP: `xcode_active_doc_changed`, `xcode_build_state_changed` (S2 substrate, unchanged).
- ADD: `xcode_build_started`, `xcode_build_finished`, `xcode_test_run_started`, `xcode_test_run_finished`, `xcode_scheme_changed`, `xcode_run_destination_changed`.

Total Xcode kinds: **8** (2 baseline + 6 new). Net registry delta: **+6**.

---

## 6. Anti-patterns from prior tracks

Source: `.claude/shared/current-state.md` "Open tensions" + Track-3/4 carry-overs + P1/P3/P4 retros.

1. **Cold-start race vs warm tick #1.** Track-3 D1+D3 hit this twice (cold tick #1 fires before warm tick #1 completes; per-channel fan-out skips). Mitigation for P2: on Agent boot, walk all DerivedData paths once → `lastSeenXcresultMtime` cursor per DerivedData hash → never emit `*_finished` for pre-existing bundles. Same posture as Linear cursor (`lastModifiedMs`).

2. **Dispatcher parity drift.** Track-3 D4 hit this — `body_kind` dispatcher missed `gh_pr_*` rename. Mitigation: every new event_kind must be added to `DispatchCoverageTests` parity fence + `ShareEventTypeRegistry.allKeys` + `ShareEventTypeDefaults` + `ActivityFeedMapper` switch. Plan: dedicated test (`#16`) enumerating all 8 `xcode_*` kinds and asserting each appears in registry + defaults + mapper.

3. **Raw third-party IDs in payloads.** Track-3 D3 → assignee anonymization. For P2: `destination.deviceName` (`"Dmitrii's MacBook Air"`) is third-party PII for shared team members on the relay. Bucketing (`macos | ios_simulator | ios_device | tv | watch | vision`) enforces walkback. Add `RelayBodyLeakageTests` sentinel for each of: `errors[].message`, `errors[].sourceURL`, `deviceName`, `modelName`, full file paths in `sourceURL`, individual test names, individual target paths.

4. **Sentinel leak regressions.** P1 used `LEAKED_SENTINEL_CLAUDE_P1`. P2 should mint `LEAKED_SENTINEL_XCODE_P2` and inject into every forbidden field across every new event_kind in `RelayBodyLeakageTests` + the moat-side cross-kind parity test in `LeafCorePrivateTests`.

5. **Don't replace S2 baseline.** Per contract §4 "the phase extends — not replaces". `XcodeStateMachine` stays; new logic lives in a sibling state machine (`XcodeBuildLifecycleStateMachine`) + a new FSEvents watcher (`XcodeDerivedDataWatcher`) — no in-place mutation of existing state-machine semantics.

6. **AppleScript timeout discipline.** Existing 1.0s script timeout is tight when scripts grow. Adding 2 more property reads (`active run destination.name`, scheme split) per tick won't blow budget — script stays one round-trip. Don't add chained tells.

7. **Multiple DerivedData hashes per workspace.** Naive watch `<hash>/Logs/Test/` would miss new project additions. Watch `~/Library/Developer/Xcode/DerivedData/*` at depth-1 with `kFSEventStreamCreateFlagWatchRoot` + listen for `ItemIsDir|ItemCreated` to discover new project hashes lazily.

8. **xcresulttool legacy flag pinning.** Xcode 16 marks current commands "legacy". Pin to `--legacy` explicit; document Xcode 27 risk in spec §X "Known caveats". Carry-over: add to `current-state.md` as an upcoming carry-over after ship.

9. **Moat placement (P3 incident).** P3 worktree shipped `Prod{Safari,Chrome,Arc}Adapter` + `BrowserBookmarkCountDeriver` + `DBDomainAllowListReader` into `LeafCorePrivate/Prod/`, but the worktree's gitignored files didn't merge cleanly — `track-6-integration` was missing them and `Cannot find 'DBDomainAllowListReader'` broke build. **Mitigation for P2:** work in `main` checkout (this branch was created from `main`, not from a worktree), not a sibling worktree. Moat files (`ProdXcodeBuildAdapter.swift`, `XcresultStructuredSummaryParser.swift`, `DerivedDataFSEventsWatcher.swift`) land directly in `Packages/LeafCorePrivate/Prod/` and are visible to the integration merge.

---

## 7. Privacy contract reaffirmed

Per contract §7 P2 + ADR-010:

**Allowed (L4 ceiling):**
- `doc_path`, `project`, `schemeName`, `targetName` (already at L4 in S2)
- `errorCount`, `warningCount`, `analyzerWarningCount`, `passedCount`, `failedCount`, `skippedCount`, `totalCount`
- `durationMs`, `startTime`, `endTime`
- `configurationName` (if added — Debug / Release / custom name)
- `runDestinationBucket` (enum, NOT raw device name)
- `status` enum (succeeded / failed / cancelled)

**Forbidden (parser strips before emit):**
- `errors[].message` (compiler error text — ADR-010 body)
- `errors[].sourceURL` (line numbers + file URLs are L4 but the text URL FORM includes raw paths — bucket to `targetName` only)
- `destination.deviceName` (raw — bucketed at provider boundary)
- `destination.modelName`, `destination.osBuildNumber` (avoid fingerprint)
- Individual test method names (user may name them descriptively → potential PII leak in "DmitriiPaymentFailureTest")
- Build log content, scheme action result.build log
- Debugger state, breakpoint locations
- Symbolic constant names from indexed sourceKit

**Walkback fences:** `RelayBodyLeakageTests` extended with `testEventBodyDoesNotLeakIntoPresenceState_XcodeP2`. Sentinel `LEAKED_SENTINEL_XCODE_P2` injected into every forbidden field across each of the 6 new event_kinds.

---

## 8. ShareEventTypeKey delta

Per contract §6.2 baseline 152 (on `main`) → P2 adds **+6** → **158** on this branch.

New keys (default OFF):
- `xcode_build_started`
- `xcode_build_finished`
- `xcode_test_run_started`
- `xcode_test_run_finished`
- `xcode_scheme_changed`
- `xcode_run_destination_changed`

Final registry total after Track-6 collective merge: 152 + 16 (P1) + 6 (P2) + 8 (P3) + 6 (P4) + ~3 (P5) + 0 (P7) ≈ **191**. Append-only — last-line fence updates on integration merge.

---

## 9. Schema additions

Per contract §6.1: **M025 reserved for P2 (optional)**. After this research, the answer is:

**No new SQLCipher table.** All 6 new event_kinds use the existing `events` table with `signal_type = attention` (matches S2 baseline) and a `payload_json.event_kind` discriminator. M025 stays reserved unused for P2 — released to the next phase that genuinely needs a table.

Justification: the only candidate for a separate table was a `xcode_build_history` rollup (per-scheme aggregate timing), but per contract §4 ("Track 6 generally does not add new MCP tools… consumers read from `events` directly") this is Phase 4.9 Derived Insights territory, not P2.

---

## 10. UI surface delta

Per contract §8 P2:

- **Settings → Local Apps → Xcode row** — extend with a "Builds & tests" sub-toggle group: 4 sub-toggles (build started/finished, test started/finished) + 2 sub-toggles (scheme changed, run destination changed). All default OFF.
- **Settings → System Observers** — new row "DerivedData watcher" (FSEvents on `~/Library/Developer/Xcode/DerivedData/`), default OFF (toggle drives the watcher start/stop; AppleScript-only path still works without it).
- No other UI changes.

Master Xcode toggle still gates everything (`LocalAppsStore.isEnabled("com.apple.dt.Xcode")` returns false → adapter doesn't poll, watcher doesn't start). Sub-toggles independent within that.

---

## 11. Questions for user (BLOCKING — answer before brainstorm)

1. **xcactivitylog binary SLF parsing — confirm SKIP?**
   Research finds the format is version-fragile (v10→v11→v12 across Xcode 14/15/26), parse requires ~500+ LOC + Xcode-version-conditional logic. xcresult bundles (stable JSON via `xcresulttool`) cover Run / Debug / Test paths — 95% of build endpoints. We'd ONLY miss error/warning counts for pure `Cmd+B` (no Run) sessions. **Recommend skip.** OK?

2. **FDA confirmation — non-blocker.**
   Live test on author's Mac: `xcrun xcresulttool` on `~/Library/Developer/Xcode/DerivedData/*/Logs/Launch/*.xcresult` runs without TCC prompt; FSEvents subscription on the same path requires no FDA. **No FDA gate needed.** Confirm: are you OK with this finding, or should I add a defensive FDA-check seam (in case Mac App Store distribution path ever sandboxes Agent)?

3. **Per-scheme allow-list (mirror P3 browser pattern) vs global ON default?**
   P3 browsers needed per-domain because URLs are L4-L5 with full URL content. Xcode equivalent depth = L4 file path + scheme name (no body content), which existing S2 already emits without per-scheme gate. **Recommend: no per-scheme allow-list.** Master `Xcode` toggle + per-event-kind ShareEventTypeKey toggles suffice. OK, or do you want per-scheme granularity for noisy multi-project setups?

4. **xcresulttool `--legacy` pinning — accept short-term, document risk?**
   Schema version 3.56 marked "legacy commands format". Apple is shipping a new command surface (`--legacy=false`) in parallel. Both work in Xcode 16+. Plan: pin to `--legacy` explicitly + feature-detect new schema for graceful degrade in Xcode 27. **Recommend: ship with `--legacy`, add carry-over to current-state.md for migration audit when Xcode 27 lands.** OK?

5. **`build_state_changed` semantic overlap with new `build_started/finished`?**
   New events fire from same AppleScript status flip but with richer payload. **Recommend: keep emitting `build_state_changed` (S2 substrate stays, contract §4 says extend not replace) AND emit the new pair in parallel.** Consumers can pick which kind they want. OK, or prefer deprecate `build_state_changed` emission while keeping registry entry?

---

## 12. Stage 0 checklist (contract §3.1)

- [x] Official vendor surfaces — AppleScript Xcode dict (live probe), xcresulttool (live probe), DerivedData layout (live probe).
- [x] WWDC / vendor sessions — Apple Developer doc (xcresulttool man), Xcode 16 release notes (schema 3.56 legacy marker).
- [x] OSS reconnaissance — XCResultKit, XCLogParser, Wakatime macos-wakatime, ActivityWatch, FastLane scan.
- [x] TCC / sandbox audit — DerivedData no FDA; xcresulttool no prompt; Hardened Runtime compatible.
- [x] Ceiling-vs-effort table — 6 Critical/Strong land; 5+ Marginal skipped or v1.1.
- [x] Anti-patterns — 9 documented from Track-3/4 + P1/P3 retros.
- [x] Phase-level questions — 5 surfaced, all blocking brainstorm.

**Status:** Ready for user answers, then Stage 1 Discovery (Explore subagent on S2 collector wiring + Track-3 LinearCollector cursor pattern) → Stage 2 brainstorm.
