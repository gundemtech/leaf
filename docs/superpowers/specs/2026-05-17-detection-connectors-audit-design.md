# Detection & Connectors Audit — alpha.17 prerelease hardening (design spec)

**Date:** 2026-05-17
**Author:** Dmitrii (dima-mac)
**Status:** Draft v1 — awaiting user review gate before plan
**Track:** standalone (not part of Track-N numbering)
**Branch convention:** `feature/detection-connectors-audit-fix-bundle` for any STOP-SHIP / MUST-FIX commits arising from execution session

---

## 1. Motivation

Track-7 (Home dashboard UI surface) collective merge landed on `main` (`abfaff07`) on 2026-05-17. In parallel, four code-style PRs (#12-15: swift-format pass, SwiftLint `--fix`, manual quick-wins, force-unwrap cleanup, tuples/params cleanup, body+cyclomatic cleanup) touched ~74 files across the codebase. Track-6 deep capture stack (P1 Claude Code, P2 Xcode, P3 Browsers, P4 Google Calendar, P5 Zoom, P6 IDEs, P7 GPT cap) landed earlier in the same week.

Three concerns motivate a focused audit before alpha.17 ships:

1. **Cross-touch risk:** 7 HIGH-risk files (`ActivityFeedMapper`, `EventKindIcon`, `GoogleCalendarEventMapper`, `SlackAPISnapshots`, `GoogleCalendarCollector`, `ClaudeCodeCollector`, `SlackAPIProvider`) were each touched by both Track-6 feature work and ≥2 code-style PRs. Mechanical formatting on logic-bearing files is the highest-leverage place for silent regressions.

2. **Build red on main:** `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/ProdSlackAPIProvider.swift:51` does not conform to `SlackAPIProvider`. The protocol was collapsed to a single-arg shape (`priors: SlackWarmStatePriorSnapshots`) in a concurrent session; the moat impl was left at the 7-arg shape. Struct is defined (`SlackAPISnapshots.swift:382`), three test files and the warm-collector call-site already updated, only the Prod adapter is stuck. Audit cannot proceed with build red.

3. **34 moat files mtime-modified in last 8 days without git visibility:** `Packages/LeafCore/Sources/LeafCorePrivate/Prod/**/*.swift` is gitignored. Concurrent sessions left changes in moat impls (Claude Code hook parsers, browser adapters, Apple desktop adapters, link derivers, OAuth providers) that no `git log` will surface. Surface-level audit can miss moat drift.

Audit scope is narrow: **capture connectors + detection logic only**. NOT Track-7 UI, NOT Sharing flow, NOT Sparkle, NOT Settings sections, NOT MCP tools.

---

## 2. Goals

- **G1** Verify substrate invariants from Track-6 collective merge are still operative after Track-7 + code-style PR churn.
- **G2** Confirm no privacy-fence (ADR-010) regression at the production data layer — sentinel injection unit tests are necessary but not sufficient.
- **G3** Identify mid-refactor states (e.g., ProdSlackAPIProvider) and close the loop deterministically.
- **G4** Establish a 3-tier prioritized audit pipeline that fits in one Claude-session execution slot (≤4 hrs author time + parallel subagent work).
- **G5** Produce actionable findings — Linear issues per severity + markdown rollup — not just a confidence statement.

---

## 3. Non-goals (hard out-of-scope)

- Track-7 UI re-test (separate acceptance gate documented in `2026-05-17-track-7-P5-polish-acceptance-gate.md`).
- Sharing flow / Phase 5 team E2E paths (separate Phase 5.4/5.5 gates).
- Sparkle update mechanics / alpha.17 build-and-ship orchestration.
- Settings sections beyond Share Controls toggles relevant to default-OFF audit dimension.
- MCP tools surfacing through user AI clients (Claude Code, Cursor, Claude Desktop).
- LeafCorePrivate moat verification at byte level — only protocol conformance + signature parity + payload-allowlist discipline.
- GCP Google Calendar OAuth wall (separate blocking gate; audit covers code paths only, not end-to-end real account).
- Phase 4.9 `ModeClassifier` impl (substrate exists, not yet executed).
- Whitepaper sync (audit findings unlikely to promote to whitepaper-level changes).

---

## 4. Substrate invariants — baseline to verify against

These counts MUST hold post-audit. Any drift without an intentional registry/schema change is STOP-SHIP.

| Invariant | Expected | Verification command |
|---|---|---|
| ShareEventTypeRegistry entries | 195 | `grep -cE "key: \"" Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` |
| DispatchCoverageTests parity fences | 23 | `grep -cE "// #[0-9]+ " Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift` |
| RelayBodyLeakageTests walkback tests | 103 | `grep -cE "^\s*func test" Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift` |
| ActivityFeedMapper switch cases | 94 (event_kinds + body-kind dispatcher tuple combined) | `grep -cE "^\s*case \"[a-z_]+\"" Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift` |
| EventKindIcon SF Symbol mappings | 47 | tabulated from `EventKindIcon.swift` switch body |
| SQLCipher migrations registered | 21 (M001-M018 + M024 + M026 + M027) | enumerate `Database.swift` `registerMigration*()` calls |
| SQLCipher tables (sum of CREATE TABLE across migrations) | 31 | sum from M001-M027 migration files |
| MCP tools | 15 (12 low-level + 3 structured) | enumerate registrations in MCP server |
| xcodebuild schemes | 5 green (LeafCore, LeafCorePrivate, Leaf, LeafAgent, LeafMCP) | `xcodebuild -list` + per-scheme build |
| SPM tests | ≥2740 (Track-7 baseline) | `swift test --enable-code-coverage` |
| `just check-tokens` 3-tier | clean (BASE+MIGRATION+RETIRED pools) | `just check-tokens` |

Any change to these counts intentional in this audit pipeline → must update the corresponding `Track-N` ship entry in `.claude/shared/current-state.md`.

---

## 5. Audit dimensions

Eight dimensions evaluated per module. Not every module has every dimension applicable — table below clarifies coverage.

### D1 — Build green
Module's enclosing target compiles in all 5 xcodebuild schemes (`LeafCore`, `LeafCorePrivate`, `Leaf`, `LeafAgent`, `LeafMCP`) plus SPM `swift build --target <Target>`. Currently violated by `ProdSlackAPIProvider`; gating until fixed.

### D2 — Unit tests pass
Module's owned tests green. Track-7 baseline: SPM 2695 XCTest + 45 Swift-Testing = 2740 total, 0 failures, 4 skipped. Skip count MUST NOT increase.

### D3 — ADR-010 walkback fence (unit layer)
Module's emitted `event_kind`s have associated RelayBodyLeakageTests walkbacks. Per kind: forbidden-field sentinel injection (`LEAKED_SENTINEL_<KIND>`) → parser → RawEvent → grep entire serialized payload for sentinel → assert absence. Currently 103 walkbacks across all kinds. Audit verifies no NEW kind landed without a paired walkback.

### D4 — Runtime smoke (Tier-1 modules only)
Author triggers real event on author's Mac → wait for collector tick → inspect SQLCipher DB via `sqlite3 events.sqlite "SELECT payload_json FROM events WHERE event_kind = '<kind>' ORDER BY id DESC LIMIT 5"` → verify payload contains expected allowlisted fields, does not contain forbidden fields. Per Tier-1 module: ≥1 representative event_kind smoked.

### D5 — Privacy fence in production data (AC-5)
Beyond unit-layer sentinels: real SQLCipher DB on author's Mac is grep'd for forbidden field substrings across a 1000-event random sample of last 7 days PLUS guaranteed ≥1 row per `event_kind` that fired at all in the window. Forbidden field substrings per kind catalogued from spec §7 below.

### D6 — Swift 6 concurrency
Build with `-warnings-as-errors=Swift6_Sendable` (already enabled per LeafCore Package.swift swiftSettings); verify no warnings. Spot-check actor isolation on Track-6 P1 hook socket listener, FSEvents watchers, AppleScript adapter registry (these are the highest-churn concurrency surfaces in last 30 days).

### D7 — Default-OFF posture (ADR-020)
Module's ShareEventTypeKey entries default to `enabledByDefault=false` for sensitive surfaces. Specifically: all 16 Track-6 P1 Claude Code kinds default OFF; all 8 P3 browser kinds default OFF; all 6 P4 GCal kinds default OFF; all 6 P2 Xcode build-state kinds default OFF; all 3 P5 Zoom kinds default OFF; all 4 P6 IDE kinds default OFF. Verify via `ShareEventTypeDefaults` registry vs known sensitive-kind allowlist (43 kinds total expected default-OFF from Track-6).

### D8 — Error handling
Graceful degrade on TCC denial / OAuth scope drop / API rate-limit / DB lock / network timeout / FSEvents stream invalidation / AppleScript permission denied. No fatal crashes. Per Tier-1 module: review error path code → confirm no `fatalError`, no force-unwrap on optionals that can be nil at runtime (force-unwrap cleanup PR #16 should have closed this — verify).

### Per-module dimension applicability

| Module category | D1 | D2 | D3 | D4 | D5 | D6 | D7 | D8 |
|---|---|---|---|---|---|---|---|---|
| Layer A collectors (NSWorkspace, FSEvents, AX) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Layer B providers (OAuth + REST/GraphQL) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| AppleScript adapters (12 apps) | ✓ | ✓ | ✓ | smoke if Tier-1 | ✓ | ✓ | ✓ | ✓ |
| State machines / coalescers | ✓ | ✓ | n/a | n/a | n/a | ✓ | n/a | ✓ |
| D3 detectors | ✓ | ✓ | ✓ | n/a (scheduled) | ✓ | ✓ | n/a | ✓ |
| Cross-cutting infra (ActivityFeedMapper, EventKindIcon, etc.) | ✓ | ✓ | parity fence | n/a | n/a | n/a | n/a | ✓ |
| Storage layer (migrations, stores) | ✓ | ✓ | n/a | n/a | n/a | ✓ | n/a | ✓ |

---

## 6. Connector inventory matrix

Snapshot from Stage 1 Discovery (Explore subagent, cross-checked against actual file reads). 32 modules total.

### 6.1 Layer A — local macOS system APIs (28 modules)

#### Foundation collectors (NSWorkspace / CGEventSource / FSEvents)

| Module | Public path | Moat path | LoC | Recent touch |
|---|---|---|---|---|
| FSEvents core | `Collectors/FSEventsCollector.swift` | `Prod/Collectors/FSEventsRouterProd.swift` | 200+160 | 7d |
| Attention / status / idle | `Collectors/AppleCollector*.swift` (foundation set) | `Prod/Collectors/Apple/*` | varies | 7d |

#### EventKit / Focus / system state (Track-4 S1)

| Module | Public path | Moat path | LoC | Notes |
|---|---|---|---|---|
| Calendar / EventKit | `OS/CalendarAppStateMachine.swift` + `CalendarAppViewObservation.swift` | `Prod/Collectors/Apple/ProdCalendarAppAdapter.swift` | 34+24+72 | TCC dual-prompt path |
| Focus mode | `OS/FocusStateMachine.swift` + `FocusObservation.swift` | none (INFocusStatusCenter native) | 20+14 | |
| System sleep/wake/lock | `Collectors/...SystemStateCollector*.swift` | n/a | — | |
| Spaces transitions | `OS/SpaceTransitionCoalescer.swift` | n/a | 24 | |

#### Track-4 S2 AppleScript apps (12 apps)

| App | StateMachine | Observation | Moat adapter | LoC |
|---|---|---|---|---|
| Music | `OS/MusicStateMachine.swift` | `MusicTrackObservation.swift` | `ProdMusicAdapter.swift` | 20+24+70 |
| Spotify | `OS/SpotifyStateMachine.swift` | `SpotifyTrackObservation.swift` | `ProdSpotifyAdapter.swift` | 36+24+70 |
| Notes | `OS/NotesStateMachine.swift` | `NotesObservation.swift` | `ProdNotesAdapter.swift` | 24+24+61 |
| Mail | `OS/MailStateMachine.swift` | `MailObservation.swift` | `ProdMailAdapter.swift` | 24+24+64 |
| Reminders | `OS/RemindersStateMachine.swift` | `RemindersCompletionObservation.swift` | `ProdRemindersAdapter.swift` | 24+14+86 |
| Calendar app | `OS/CalendarAppStateMachine.swift` (S1) | — | `ProdCalendarAppAdapter.swift` | (S1) |
| Xcode | `OS/XcodeStateMachine.swift` + lifecycle SMs | `XcodeObservation.swift` | `ProdXcodeAdapter.swift` + S2/P2 watchers | 36+24+82 |
| Safari | `OS/SafariStateMachine.swift` + active + nav | `SafariObservation.swift` | `ProdSafariAdapter.swift` | 36+38+40+28+201 |
| Chrome | `OS/ChromeStateMachine.swift` + active + nav | `ChromeObservation.swift` | `ProdChromeAdapter.swift` | 37+38+36+28+200 |
| Arc | `OS/ArcStateMachine.swift` + active + nav | `ArcObservation.swift` | `ProdArcAdapter.swift` | 38+40+40+27+201 |
| Zoom | `OS/ZoomStateMachine.swift` + topic redactor + linker + duration tracker | `ZoomObservation.swift` | `ProdZoomAdapter.swift` + linker + redactor + thresholds | 38+24+40+40+30+145+93+34+18 |
| AppleScript bridge | `OS/AppleScriptAdapter.swift` (5 files: Bridge, Registry, PermissionStore, DispatchLogic) | `Prod/Collectors/Apple/ProdAppleScriptAdapterRegistry.swift` | 52-86 public + 30 moat | infrastructure |

#### Track-4 S3 system observers (10 modules)

| Module | Public path | Moat | LoC |
|---|---|---|---|
| Audio route | `OS/AudioRouteStateMachine.swift` + `AudioRouteCategory.swift` | native CoreAudio | 20+17 |
| Mic in-use | `OS/MicInUseStateMachine.swift` | native | 24 |
| Display / screen | `OS/DisplayStateMachine.swift` + `ScreenshotMatcher.swift` | native CGDisplay | 44+36 |
| WiFi | `OS/WiFiStateMachine.swift` | native CoreWLAN | 48 |
| VPN | `OS/VPNStateMachine.swift` | native NEVPNConnection | 48 |
| Clipboard counter | `OS/ClipboardCounterStateMachine.swift` | native NSPasteboard | 24 |
| Downloads / Trash | `OS/DownloadsMatcher.swift` + `TrashMatcher.swift` | native FSEvents | 24+36 |
| Run destination bucket | `OS/RunDestinationBucket.swift` | n/a | 35 |
| Intensity (CGEventTap, Track-4 S3) | `Collectors/IntensityCollector*.swift` | gitignored intensity aggregator | varies |
| `presence_state` writer | `DB/PresenceStateWriter.swift` | n/a | ~200 |

#### Track-6 P1 Claude Code (hybrid jsonl + hook bridge)

| Module | Public path | Moat path | LoC |
|---|---|---|---|
| Claude Code collector | `Collectors/ClaudeCodeCollector.swift` | — | 498 |
| Hook parser | `Collectors/ClaudeCodeHookParser*.swift` | `Prod/Collectors/ClaudeCodeHookParser.swift` | varies + 292 |
| Hook socket listener | — | `Prod/Collectors/ClaudeCodeHookSocketListener.swift` | 236 |
| JSONL parser | `Collectors/ClaudeCodeJSONLParsing.swift` | `Prod/Collectors/ClaudeCodeJSONLParser.swift` | 40+578 |
| Subagent meta reader | — | `Prod/Collectors/ClaudeCodeSubagentMetaReader.swift` | 66 |
| `leaf-hook-bridge` executable | `Sources/LeafHookBridge/` | n/a (public) | ~250 |
| Hook installer (Settings UI) | `Onboarding/AIToolsHookInstaller.swift` | — | varies |

#### Track-6 P2 Xcode deep (build / test / scheme / destination)

| Module | Public path | Moat path | LoC |
|---|---|---|---|
| Build lifecycle SM | `OS/XcodeBuildLifecycleStateMachine.swift` | — | 46 |
| Test run SM | `OS/XcodeTestRunStateMachine.swift` | — | 48 |
| DerivedData FSEvents watcher | — | `Prod/Collectors/Apple/ProdDerivedDataWatcher.swift` | 273 |
| xcresult parser | — | `Prod/Collectors/Apple/ProdXcresultParser.swift` | 231 |
| Provider snapshots cursor (DerivedData) | `DB/DerivedDataCursor.swift` | uses M015 `provider_snapshots` table | varies |

#### Track-6 P3 Browsers deep (per-domain AppleScript + bookmark count delta)

| Module | Public path | Moat path | LoC |
|---|---|---|---|
| Browser bookmarks watcher | `Collectors/BrowserBookmarksWatcher.swift` | `Prod/Collectors/BrowserBookmarkCountDeriver.swift` | 205+63 |
| Per-browser nav + active SMs | `OS/Safari/Chrome/ArcNavStateMachine.swift` + `*ActiveStateMachine.swift` | adapters above | (counted in S2 table) |
| Domain allow-list reader | `OS/BrowserDomainAllowList.swift` | `Prod/Collectors/DBDomainAllowListReader.swift` | varies |
| M026 table | `DB/Migrations/M026_BrowserDomainAllow.swift` | — | — |

#### Track-6 P5 Zoom deep (duration + calendar linker + topic redaction)

(Inline with AppleScript S2 table above; included for explicit P5 traceability)

| Module | Public path | Moat path |
|---|---|---|
| Duration tracker | `OS/ZoomMeetingDurationTracker.swift` | `Prod/Collectors/Apple/ProdZoomDurationTrackerThresholds.swift` |
| EventKit calendar linker | `OS/ZoomCalendarLinker.swift` | `Prod/Collectors/Apple/ProdZoomCalendarLinker.swift` |
| Topic redactor (L4 PMI strip) | `OS/ZoomMeetingTopicRedactor.swift` | `Prod/Collectors/Apple/ProdZoomMeetingTopicRedactor.swift` |

#### Track-6 P6 VSCode-family + JetBrains

| Module | Public path | Moat path | LoC |
|---|---|---|---|
| VSCode workspace watcher | `Collectors/VSCodeWorkspaceWatcher.swift` | — | 166 |
| VSCode-family dispatcher | `Insights/Parsers/VSCodeFamily/VSCodeFamilyDispatcher.swift` | — | varies |
| Per-fork title parsers (Stable/Insiders/Cursor/Codium) | `Insights/Parsers/VSCodeFamily/*.swift` | — | 261 (7 files) |
| IDE title path sanitizer | `Insights/Parsers/VSCodeFamily/IDETitlePathSanitizer.swift` | — | varies |
| JetBrains recent-projects watcher | `Collectors/JetBrainsRecentProjectsWatcher.swift` | `Prod/Collectors/Apple/ProdJetBrainsAdapter.swift` + `ProdJetBrainsProductMap.swift` | 195+87+44 |

### 6.2 Layer B — external OAuth / API providers (4 modules)

| Provider | Public files | Moat impl | Total LoC | Status |
|---|---|---|---|---|
| GitHub | `Integrations/GitHub/` (8 files) + `Collectors/GitHubCollector.swift` (+ Warm + Cold) | `Prod/Collectors/ProdGitHubAPIProvider.swift` | 539 + 2196 + 2246 | OK |
| Linear | `Integrations/Linear/` (7 files) + `Collectors/LinearCollector.swift` (+ Warm + Cold) | `Prod/Collectors/ProdLinearGraphQLProvider.swift` | 860 + 2186 | OK |
| Slack | `Integrations/Slack/` (8 files) + `Collectors/SlackCollector.swift` (+ Warm + Cold) | `Prod/Collectors/ProdSlackAPIProvider.swift` | 540 + 1932 | **BUILD RED @ line 51 / 1175** |
| Google Calendar | `Integrations/GoogleCalendar/` (9 files) + `Collectors/GoogleCalendarCollector.swift` | none (GCP OAuth wall) | 1693 | OK code-only; runtime wall |

### 6.3 Cross-cutting infrastructure (already itemized in §7 Detection inventory below)

---

## 7. Detection inventory matrix

### 7.1 Track-1 D3 detectors (5 detectors + orchestrator)

| Detector | Public location | Moat impl | Lines | Output table | Tests |
|---|---|---|---|---|---|
| DecisionDetector | `Detection/Protocols.swift` (protocol) | `Prod/Detection/ProdDecisionDetector.swift` | 154 | `decisions` | DetectorPipeline integration |
| OpenQuestionDetector | `Detection/Protocols.swift` | `Prod/Detection/ProdOpenQuestionDetector.swift` | ~108 | `open_questions` | DetectorPipeline integration |
| BlockerPatternDetector | `Detection/Protocols.swift` | `Prod/Detection/ProdBlockerPatternDetector.swift` | ~60 | `blockers` | DetectorPipeline integration |
| LinearStuckScanner (scheduled) | `Detection/Protocols.swift` | `Prod/Detection/ProdLinearStuckScanner.swift` | ~95 | `blockers` (kind=linear_stuck) | DetectorPipeline integration |
| WhereStoppedDeriver (scheduled) | `Detection/Protocols.swift` | `Prod/Detection/ProdWhereStoppedDeriver.swift` | ~138 | `where_stopped_log` | DetectorPipeline integration |
| DetectorPipeline (orchestrator) | `Detection/DetectorPipeline.swift` | — | 499 | n/a | 23 parity fences (DispatchCoverageTests) |
| DetectorMoat (boundary) | `Detection/DetectorMoat.swift` | — | ~80 | n/a | — |
| Detection protocols | `Detection/Protocols.swift` | — | ~60 | n/a | — |

**Moat support files (8):** `PRHashRefParser.swift`, `PRURLParser.swift`, `LinkConfidence.swift`, `ProdLinkDerivers.swift`, `ProdDetectorMoat.swift`, `BodyExcerptCap.swift`, `BranchNameLinearParser.swift`, `ProdAbsenceMatcher.swift`.

### 7.2 Cross-cutting infrastructure

| Module | File | Lines | Counts |
|---|---|---|---|
| ActivityFeedMapper | `Insights/ActivityFeedMapper.swift` | 994 | 94 switch cases (33+ event_kinds + body-kind dispatcher tuple) |
| EventKindIcon | `Insights/EventKindIcon.swift` (or UI/) | 122 | 47 SF Symbol mappings |
| DispatchCoverageTests | `Tests/LeafCoreTests/DispatchCoverageTests.swift` | varies | 23 parity fences |
| RelayBodyLeakageTests | `Tests/LeafCoreTests/RelayBodyLeakageTests.swift` | varies | 103 walkback test functions |
| LinearIDExtractor | `Collectors/LinearIDExtractor.swift` | ~120 | regex `[A-Z][A-Z0-9]{1,4}-\d+` + prefix whitelist |
| EventLinksStore | `DB/EventLinksStore.swift` | 394 | writes to `event_links` (M013) |
| LinkDerivers (moat) | `Prod/Detection/ProdLinkDerivers.swift` | ~180 | confidence scoring + extractors |
| PresenceStateWriter | `DB/PresenceStateWriter.swift` | ~200 | writes `presence_state` (M005, composite per provider) |
| PresenceSnapshot | `Presence/PresenceSnapshot.swift` | ~150 | immutable snapshot value type |
| ShareEventTypeRegistry | `Share/ShareEventTypeRegistry.swift` | 550 | 195 enum cases |
| ShareEventTypeDefaults | (same file or sibling) | varies | default-OFF list per ADR-020 |
| ShareControlsFilter | `Share/ShareControlsFilter.swift` | varies | pre-encryption filter (Agent) |

### 7.3 State machines & coalescers (>=20 modules)

| Category | Count | Examples |
|---|---|---|
| Track-4 S1 system | 6 | Calendar/Mail/Reminders/Display/VPN/AudioRoute |
| Track-6 P2 Xcode | 2 | BuildLifecycle, TestRun |
| Track-6 P3 Browser | 6 | Safari/Chrome/Arc × {Nav, Active} |
| Track-6 P5 Zoom | 1 | MeetingDurationTracker (+ linker + redactor) |
| Track-6 P6 IDE | 1 | VSCodeFamilyDispatcher |
| Track-4 S3 intensity | 1 | IntensityAggregator (CGEventTap) |
| Track-6 P1 Claude Code | 1 | tool_use_id LRU dedup |
| Cross-cutting | 3 | SpaceTransitionCoalescer, ScreenshotMatcher, DownloadsMatcher |

---

## 8. Risk priority ranking (from Stage 1 recent-touch map)

### HIGH (7 files — touched ≥5x by Track-6 features + ≥2 code-style PRs)

1. `Insights/ActivityFeedMapper.swift` — 21 touches (18 feature + 3 style passes including P2.3.C.2 cyclomatic cleanup)
2. `Insights/EventKindIcon.swift` (or UI/) — 15 touches (13 feature + 2 style P2.1/P2.3.C.2)
3. `Integrations/GoogleCalendar/GoogleCalendarEventMapper.swift` — 8 touches (4 feature + 4 style)
4. `Integrations/Slack/SlackAPISnapshots.swift` — 6 touches (4 feature + 2 style)
5. `Collectors/GoogleCalendarCollector.swift` — 6 touches (3 feature + 3 style)
6. `Collectors/ClaudeCodeCollector.swift` — 6 touches (3 feature + 3 style P2.1/P2.2/P2.3.B)
7. `Integrations/Slack/SlackAPIProvider.swift` — 5 touches (3 feature + 2 style)

### MED (6 files — 4-5 touches, similar mix)

8. `OS/ZoomMeetingDurationTracker.swift`
9. `Integrations/GoogleCalendar/GoogleCalendarOAuthEndpoints.swift`
10. `Integrations/GitHub/GitHubAPISnapshots.swift`
11. `OS/XcodeBuildLifecycleStateMachine.swift`
12. `Collectors/SlackWarmCollector.swift`
13. `Collectors/GitHubWarmCollector.swift`

### LOW (~19 modules)

All remaining Layer A state machines + Layer B warm/cold collectors not in HIGH/MED. Each touched 1-3 times max, mostly style-only formatting passes.

### Moat (34 files — mtime-modified last 8 days, no git history)

- ClaudeCode: ClaudeCodeHookParser, ClaudeCodeHookSocketListener, ClaudeCodeJSONLParser, ClaudeCodeSubagentMetaReader
- Browser: ProdArcAdapter, ProdChromeAdapter, ProdSafariAdapter, BrowserBookmarkCountDeriver, DBDomainAllowListReader
- Apple Desktop: ProdXcodeAdapter, ProdXcresultParser, ProdDerivedDataWatcher, ProdMailAdapter, ProdNotesAdapter, ProdRemindersAdapter, ProdMusicAdapter, ProdSpotifyAdapter, ProdCalendarAppAdapter, ProdJetBrainsAdapter, ProdJetBrainsProductMap, ProdZoomAdapter, ProdZoomMeetingTopicRedactor, ProdZoomDurationTrackerThresholds, ProdZoomCalendarLinker
- Integrations: ProdSlackAPIProvider, ProdGitHubAPIProvider, ProdLinearGraphQLProvider
- Detection: ProdAppCategoryClassifier, LinkConfidence, ProdLinkDerivers, ProdWhereStoppedDeriver
- Config / Insights: AgentThresholdsProd, ProdInsights

---

## 9. Stop-ship conditions

Audit halts and findings escalate to **STOP-SHIP** if any of these are true at execution-session start or after Stage 5.0 pre-audit gate:

- **SS-1** Any of 5 xcodebuild schemes red (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
- **SS-2** SPM test suite has ≥1 failure or skip count > 4 (Track-7 baseline).
- **SS-3** Any RelayBodyLeakageTests walkback function failing (privacy fence breach at unit layer).
- **SS-4** Any DispatchCoverageTests parity fence broken (mapper/registry/icon/store coverage drift).
- **SS-5** AC-5 production-data grep returns ≥1 forbidden-field hit within 1000-sample window for any audited `event_kind`.
- **SS-6** ShareEventTypeRegistry entry count ≠195 without an explicit registry-extension commit in the audit branch.
- **SS-7** Migration count ≠21 or table count ≠31 (substrate drift).
- **SS-8** ProdSlackAPIProvider protocol conformance not restored (currently violated).

STOP-SHIP requires inline fix before further audit work. SS-1 and SS-8 are entry-gate conditions — Stage 5.0 must close them or audit does not start.

---

## 10. Severity classes for findings

| Severity | Definition | Disposition |
|---|---|---|
| **STOP-SHIP** | Any condition from §9 | Inline fix in execution session, single-commit per fix, on `feature/detection-connectors-audit-fix-bundle` branch. |
| **MUST-FIX** | Functional regression in Track-6 capture path / Track-7 drill-down data plumbing / privacy posture without unit-layer breach (e.g., default-OFF mis-configured) | Inline if scope ≤3 commits, else defer to next-day session with Linear issue + plan link. |
| **NICE-TO-HAVE** | Cleanup, doc gaps, optimization, missing test coverage on non-critical path, minor code-style residual not caught by Phase 2.x PRs | Linear issue with `audit-followup` label, defer to v1.1 backlog. Never blocks alpha.17. |

---

## 11. Three-tier execution structure

### Tier 1 — author-driven manual smoke (sequential, ~3-4 hrs)

13 modules: 7 HIGH + 6 MED.

For each module: trigger real event on author's Mac → wait collector tick (≤5 min) → `sqlite3` DB query → assert expected allowlisted fields present + forbidden fields absent → tick D1-D8 dimensions inline per applicability matrix from §5.

Specific trigger script per module documented in Plan §3.

### Tier 2 — parallel subagent code-audit (concurrent, ~30 min wall)

~19 LOW-risk modules + 34 moat files. Dispatch 4-5 Explore subagents on disjoint clusters:

- **Cluster A:** remaining Layer A locals (S1 system + S3 observers + Track-4 S2 AppleScript apps excluding HIGH/MED).
- **Cluster B:** Layer B providers other than Slack (Linear + GitHub + GoogleCalendar code-paths, excluding HIGH/MED files already audited).
- **Cluster C:** Track-6 P3 browsers + P6 IDEs.
- **Cluster D:** Detection moat impls (5 detectors + 8 support files).
- **Cluster E:** State machines & coalescers + cross-cutting infra non-HIGH.

Each subagent returns per-module 8-dimension checklist (✓ / ✗ / N/A per dimension) + findings narrative ≤200 words per cluster.

### Tier 3 — parity-fence verification (automated, ~5 min)

- All 5 xcodebuild schemes Debug build (parallel, `xcodebuild -project Leaf.xcodeproj -scheme <S> build` × 5).
- `swift test` full suite.
- `just check-tokens` (3-tier clean).
- `just check-style` (current style baseline holds).
- Count fences per §4: registry 195 / dispatch 23 / walkback 103 / mapper 94 / icon 47 / migrations 21 / tables 31.

---

## 12. Findings format

### Markdown rollup

Single file `~/Desktop/Leaf/leaf/.claude/audit/2026-05-17-detection-connectors-audit-findings.md` (gitignored — NOT `.claude/shared/` which auto-loads into every session).

Structure:
```
# Detection & Connectors Audit — findings rollup
**Date executed:** 2026-05-MM
**Pre-audit gate:** PASS/FAIL (Stage 5.0 status)
**Substrate invariants:** PASS/FAIL (Stage 5.3 counts)

## STOP-SHIP findings
- [F-001] <one-line> — module: X, dimension: D5, fix: <inline commit hash or planned>

## MUST-FIX findings
- [F-010] ...

## NICE-TO-HAVE findings
- [F-100] ...

## Tier 1 manual smoke matrix (13 modules × 8 dimensions)
| Module | D1 | D2 | D3 | D4 | D5 | D6 | D7 | D8 | Notes |
| ...

## Tier 2 subagent reports
### Cluster A — Layer A locals
...
```

### Linear issues

One issue per finding above NICE-TO-HAVE severity. Title prefix matches severity: `[STOP-SHIP] ...`, `[MUST-FIX] ...`. Label `audit-2026-05-17`. Project: `Leaf`. Link to rollup line.

---

## 13. Coordination

**Solo audit.** Anton currently on `feature/track-5-S7-team-ui` (disjoint scope — team UI, not capture/detection). leaf-presence MCP shows 0 handoffs/questions/drifts to me. One concurrent dima session active on `feature/code-style-phase-2-3-C-3-4-type-file` worktree splitting test fixture-heavy files — isolated worktree, no interference with audit scope.

Pre-share executive summary to Anton via `leaf_handoff_create` only if findings touch substrate invariants he relies on (presence_state schema, M005-M009 team tables, ShareEventTypeRegistry that team UI consumes).

---

## 14. Resolved brainstorm questions

### Q1 — Sample size for AC-5 (privacy fence in prod data)
**Resolution:** 1000 events random-sampled across last 7 days + guaranteed ≥1 row per `event_kind` that fired at all in the window.
**Rationale:** 100 too small for rare emission paths (e.g., `zoom_meeting_calendar_linked`, GCal `working_location_changed`). 30 days expensive and mostly repetitive. Unit-layer sentinel injection (RelayBodyLeakageTests 103 walkbacks) is the primary fence; AC-5 is the cross-layer reality check.

### Q2 — Runtime smoke matrix scope
**Resolution:** Three-tier — Tier 1 (13 modules, author manual smoke, 8 dimensions); Tier 2 (~19 LOW + 34 moat files, parallel subagent code-audit, dimension checklist); Tier 3 (automated parity-fence verification).
**Rationale:** Full matrix (32 modules × 8 dimensions = 256 cells) unrealistic in single execution session. Risk-prioritized Tier 1 covers Stage 1 HIGH+MED set; Tier 2 catches LOW + moat drift; Tier 3 catches everything else through fence breakage.

### Q3 — ProdSlackAPIProvider mid-refactor
**Resolution:** Finalize the collapse. Becomes Task 0 in execution plan, gates audit start.
**Rationale:** Struct already public-defined (`SlackAPISnapshots.swift:382`); protocol uses single-arg shape; 1 production call-site + 3 test files already updated; only Prod impl is stuck. Reverting means undoing 6 public-substrate changes; finalizing means updating 1 file mechanically.

### Q4 — Multi-Mac coordination with Anton
**Resolution:** Solo audit. No handoff required at start.
**Rationale:** Anton on `feature/track-5-S7-team-ui` (orthogonal scope). 0 handoffs/questions/drifts. Notify post-audit only if substrate invariants impacting team UI surfaced.

### Q5 — Findings format
**Resolution:** Hybrid — markdown rollup at `.claude/audit/2026-05-17-detection-connectors-audit-findings.md` (gitignored) + Linear issues per STOP-SHIP / MUST-FIX finding.
**Rationale:** `.claude/shared/` auto-loads into every session — bloating context with stale audit notes is anti-pattern. Linear is the team tracker; rollup is session-artifact for execution-session reference.

### Q6 — Fix-bundle inline vs defer
**Resolution:** Severity-tiered (§10). STOP-SHIP inline; MUST-FIX inline if ≤3 commits else next-day session; NICE-TO-HAVE Linear-only defer.
**Rationale:** Single execution session can absorb a few inline STOP-SHIP fixes (Slack rebuild + 1-2 derivative fixes) but cannot absorb open-ended MUST-FIX bundle. Defer prevents scope creep.

---

## 15. Acceptance criteria (audit closure)

Audit closes successfully when:

- **AC-1** Stage 5.0 pre-audit gate PASS (Slack rebuild → all 5 schemes green, SPM green).
- **AC-2** Tier 1 (13 modules × 8 dimensions = 104 cells, minus N/A) complete with rollup matrix populated.
- **AC-3** Tier 2 (5 cluster subagent reports) returned and digested into rollup.
- **AC-4** Tier 3 parity-fence verification: all 11 §4 invariants PASS.
- **AC-5** Privacy fence in prod data: 1000-event sample + per-kind ≥1 row grep returns 0 forbidden-field hits.
- **AC-6** All STOP-SHIP findings (if any) fixed inline with commit links in rollup.
- **AC-7** All MUST-FIX findings either fixed inline or filed in Linear with `audit-followup` label and target date.
- **AC-8** All NICE-TO-HAVE findings filed in Linear with `audit-followup` label.
- **AC-9** Rollup file committed locally (gitignored) AND Linear issues posted.
- **AC-10** `.claude/shared/current-state.md` updated with audit closure entry (one paragraph).

Relaxed acceptance: AC-9 Linear posting can be batched up to 1 day post-audit; rollup must be present at audit closure.

---

## 16. Session-kickoff prompt for execution session

```
Executing Detection & Connectors Audit (Stages 5-7) per spec
`docs/superpowers/specs/2026-05-17-detection-connectors-audit-design.md`
and plan `docs/superpowers/plans/2026-05-17-detection-connectors-audit.md`.

Start-of-session chores (per conventions.md):
- git fetch --all --prune
- git -C ~/Desktop/Leaf/leaf-docs pull --ff-only --quiet
- git branch -r --sort=-committerdate | head -10
- leaf-presence MCP handoff/question/drift check
- git checkout main + git log -1 (verify on top of latest main)

Then proceed with Stage 5.0 pre-audit gate:

1. Finalize ProdSlackAPIProvider (Task 0):
   - Open Packages/LeafCore/Sources/LeafCorePrivate/Prod/Collectors/ProdSlackAPIProvider.swift
   - Update `fetchWarmState` signature from 7 separate prior-snapshot args
     to single `priors: SlackWarmStatePriorSnapshots` arg
   - Update internal call sites (priorMemberChannels → priors.priorMemberChannels, etc.)
   - Single commit on `feature/detection-connectors-audit-fix-bundle` off main
2. Build all 5 xcodebuild schemes — confirm green.
3. Run full SPM test suite — confirm 2740 pass, ≤4 skipped, 0 failures.
4. Verify Tier-3 parity-fence counts per spec §4.

Only proceed to Stage 5.1 manual smoke if Stage 5.0 PASS. If FAIL, fix
and retry; if fix scope >2 hrs, halt audit and report.

Stage 5.1 manual smoke per Plan §3 (13 modules × applicable dimensions).
Stage 5.2 parallel subagent code-audit per Plan §4 (5 clusters).
Stage 5.3 Tier-3 parity-fence per Plan §5 (automated, ~5 min).
Stage 5.4 findings rollup + Linear filings per Plan §6.

Findings file: ~/Desktop/Leaf/leaf/.claude/audit/2026-05-17-detection-
connectors-audit-findings.md (gitignored — create directory if needed).

Reference docs:
- .claude/shared/architecture.md (full connector / detection context)
- .claude/shared/current-state.md (Track-7 + Track-6 + code-style PR
  landing entries, freshly updated 2026-05-17)
- This spec for invariants, dimensions, stop-ship conditions.
```

---

## 17. Open tensions

- **OT-A** AC-5 prod-data grep relies on author's Mac having representative event distribution across all 195 ShareEventTypeKey kinds. Many Track-6 P4 / P5 / P6 kinds may not have fired in author's last 7 days (e.g., no Google Calendar focus_block created, no Zoom meetings linked). Mitigation: per-kind guaranteed-one requirement is best-effort; missing kinds documented in rollup with explanation, not treated as STOP-SHIP.

- **OT-B** Tier-2 subagent code-audit cannot validate runtime behavior (no event triggers, no DB inspection). Subagents only check code paths via read. Findings of class "looks fine on read" are weaker than Tier-1 findings. Mitigation: explicit confidence tag in rollup ("code-audit only" vs "smoke-verified").

- **OT-C** 34 moat files mtime-modified without git history means audit cannot reconstruct intent. If a moat file shows mismatch with public protocol (à la ProdSlackAPIProvider), only path forward is finalize-or-revert decision per file. Spec assumes ≤2 such cases; if >5, halt and consult.

- **OT-D** Code-style PRs landed without re-running full integration test matrix per file (CI is report-only per Phase 1 spec). Audit Tier-1 is implicit integration coverage on HIGH-risk files but not exhaustive. Trade-off: ship alpha.17 with audit coverage on HIGH-risk subset OR delay alpha.17 for full integration matrix. Spec accepts subset coverage; deferred items go to alpha.18 audit.

---

## Appendix A — Forbidden field substrings per event_kind (excerpt; full table in execution session)

ADR-010 / Track-6 walkback discipline. Below is representative subset for AC-5 grep target set. Full enumeration of ~120 forbidden substrings across 195 kinds belongs in `Prod/Detection/ADR010ForbiddenFields.swift` (moat) — execution session generates full list from code.

| Event kind family | Forbidden substrings (in `payload_json`) |
|---|---|
| `claude_*` | `command`, `tool_input`, `tool_response`, `content`, `thinking`, `signature`, `old_string`, `new_string`, `iterations`, `prompt`, `url`, `prompt_text`, `output_text` |
| `xcode_*` | `errors[].message`, `sourceURL`, `destination.deviceName`, `modelName`, test names, build log substrings |
| `safari_*` / `chrome_*` / `arc_*` | URL beyond allowlist granularity (path stripped for `domain_only`), bookmark title text, tab title text |
| `google_calendar_*` | `decline_message`, `building_id`, `attendee_email`, `description`, `conference_uri`, `location`, `creator_email` |
| `zoom_*` | full meeting name (post-redaction), PMI (L4 redact at parser boundary), attendee list |
| `vscode_*` | absolute path, file contents, debugger state |
| `slack_*` | message body text, channel name (DM channels → `DM` bucket), file content, full thread text |
| `linear_*` | issue body text, comment body text, document content, attendee PII |
| `gh_*` | commit message body (above first line / 72 chars), PR description body, review comment body, file diff content |
| Intensity (`intensity_*`) | foreground app when locked, keystroke content (only count bucket persisted) |

---

## Appendix B — verification commands reference

Quick-reference verification snippets used in Tier 3 parity-fence (§4 + §11 Tier 3):

```bash
# Substrate invariants
grep -cE "key: \"" Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift
grep -cE "// #[0-9]+ " Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift
grep -cE "^\s*func test" Packages/LeafCore/Tests/LeafCoreTests/RelayBodyLeakageTests.swift
grep -cE "^\s*case \"[a-z_]+\"" Packages/LeafCore/Sources/LeafCore/Insights/ActivityFeedMapper.swift

# Migration registration enumeration
grep -nE "migrator\.registerMigration[0-9]+" Packages/LeafCore/Sources/LeafCore/DB/Database.swift

# Build matrix (run in parallel)
for s in LeafCore LeafCorePrivate Leaf LeafAgent LeafMCP; do
    xcodebuild -project Leaf.xcodeproj -scheme "$s" -configuration Debug build &
done; wait

# SPM test suite
cd Packages/LeafCore && swift test --parallel 2>&1 | tail -30

# AC-5 prod-data sample
sqlite3 ~/Library/Application\ Support/Leaf/events.sqlite "
    SELECT event_kind, payload_json
    FROM events
    WHERE ts_ms > strftime('%s', 'now', '-7 days') * 1000
    ORDER BY random()
    LIMIT 1000
" > /tmp/leaf-audit-sample.tsv

# Per-kind guaranteed one
sqlite3 events.sqlite "
    SELECT DISTINCT event_kind FROM events
    WHERE ts_ms > strftime('%s', 'now', '-7 days') * 1000
" | while read kind; do
    sqlite3 events.sqlite "SELECT payload_json FROM events WHERE event_kind = '$kind' ORDER BY id DESC LIMIT 1" \
        >> /tmp/leaf-audit-per-kind.tsv
done

# Forbidden-field grep (per kind, from Appendix A)
# Example for claude_*:
grep -E "(\"command\":|\"tool_input\":|\"tool_response\":|\"content\":|\"thinking\":|\"signature\":)" /tmp/leaf-audit-sample.tsv | head -20
```

---

**End of spec.** Plan file is sibling `docs/superpowers/plans/2026-05-17-detection-connectors-audit.md` (gitignored, ≥300 lines, atomic tasks).
