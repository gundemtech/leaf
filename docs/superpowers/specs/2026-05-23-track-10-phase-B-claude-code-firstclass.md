# Track-10 Phase B — Claude Code workflow first-class в YOU'RE ON

**Linear:** GUN-B (placeholder)
**Status:** IN PROGRESS — Stage 3 spec landing.
**Parent:** master spec §9.2 carries C-T10-EMIT-T7H1 / C-T10-EMIT-T7H2 / C-T10-EMIT-T7H3.
**Branch:** `feature/GUN-B-track-10-claude-code-workflow-firstclass` off `feature/track-10-operational-home` tip `216bdc5e` (Phase A SHIPPED).
**Date:** 2026-05-23.

---

## 1. Scope

Closes 3 T7 post-ship moat hot-fix carries by legitimizing the moat changes via public LeafCore substrate-pure additions + symmetric IDE-vs-AI compare-by-latestTs + sentinel-injection regression test. **Substrate-purity invariant held** — registry 198 / 30 tables / 15 MCP tools frozen. CurrentTaskSession struct grows by 1 field (15th defaulted-init iteration, backward-compatible).

After Phase B SHIPPED → master spec §9.2 closes 3 carries (T7H1 + T7H2 + T7H3), leaving only C-25 / pre-existing flake / v1.1 carries.

### 1.1 In-scope (3 hot-fix legitimizations)

1. **C-T10-EMIT-T7H1 — Multi-prefix Linear ID resolution**: `knownPrefixes: Set<String> = ["LEAF", "GUN"]` hardcoded in moat works for current users. Phase B legitimizes the moat (already-landed) but does NOT introduce `LinearIDPrefixCache` v1.1 live-sync (separate phase if other workspaces onboard).

2. **C-T10-EMIT-T7H2 — aiCollaboration cwd fallback**: moat `resolveMostRecentAICollaborationCwd` (CurrentTaskIdentity) + `tryAICollaborationFallback` (CurrentTaskSession) already-landed. Phase B adds:
   - **Symmetric compare-by-latestTs** (Brainstorm gate decision — "AI wins if more recent"): rewrite `perIDEEarliestEventTodayMatchingWorkspace` to compute **both** an IDE candidate and an aiCollaboration cwd-match candidate today, pick the one with higher `MAX(ts)` (most-recent activity in workspace). sessionStartMs = winning source's earliest event ts today.
   - `CurrentTaskSession.sessionSource: SessionSource` field (15th defaulted-init iteration) carries the winning source enum {ide, aiCollaboration, fallback}.
   - `YoureOnRowComposer.composeSessionLine` appends " via Claude Code" suffix when `sessionSource == .aiCollaboration`.

3. **C-T10-EMIT-T7H3 — terminalFamily dwell multi-bundle**: moat already uses `bundleIDs: [String]` signature. Phase B hoists `terminalFamilyBundleIDs` from moat-private `static let` to public `IDEFamilyClassifier.terminalFamilyBundleIDs: Set<String>` for cross-extension reuse.

4. **Sentinel-injection regression test** (moat-side, gitignored): inject sentinel string into `aiCollaboration.payload_json.$.cwd` field; verify sentinel never appears in returned `TaskIdentity.workspacePath` / `CurrentTaskSession.openFiles` / `branch`. Closes the master spec §9.2 T7H3 note "currently moat-tested via happy path only".

### 1.2 Out of scope

- **LinearIDPrefixCache v1.1** (live Linear workspace prefix sync) — separate phase if multi-workspace onboarding surfaces. Hardcoded `["LEAF", "GUN"]` ships.
- **YoureOnBlock `sessionSource` UI variants beyond text suffix** — current scope: text suffix only. Visual indicator (icon, color) deferred to UX polish.
- **C-25 sleep/wake** — Phase C.
- **Other Track-10 §9.2 open carries** — STANDUP-HOURS / MCP-STANDUP / FLAKE / LOC-RESUMEHERO informational.

---

## 2. Decisions (Stage 2 brainstorm)

**D-B1.** **Brainstorm gate resolved (user-confirmed 2026-05-23):** AI wins if more recent. Pick source by `MAX(ts) DESC` among {IDE, aiCollaboration} cwd-match candidates today.

**D-B2.** `SessionSource` enum **public LeafCore** addition. Field `sessionSource: SessionSource = .fallback` 15th defaulted-init iteration on `CurrentTaskSession`. Backward-compat preserved.

**D-B3.** Hoist `terminalFamilyBundleIDs` from moat-private to public `IDEFamilyClassifier.terminalFamilyBundleIDs: Set<String>`. Moat adopts via `IDEFamilyClassifier.terminalFamilyBundleIDs`. Cross-extension reuse opportunity (future filters / detail screens).

**D-B4.** Composer renders ` via Claude Code` suffix when sessionSource = .aiCollaboration. No other UI variants in Phase B (icon / color deferred).

**D-B5.** Sentinel-injection test sits **moat-side** in `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/` (gitignored). Tests cwd never leaks into `TaskIdentity` / `CurrentTaskSession`. Closes T7H3 "happy-path-only" gap.

**D-B6.** No SQLCipher / event_kind / MCP tool delta — substrate-purity invariant preserved.

**D-B7.** Atomic commit sequence ~9 commits. View + composer changes are tight (1 file each).

---

## 3. Per-fix implementation

### 3.1 Public LeafCore — `IDEFamilyClassifier.terminalFamilyBundleIDs`

`Packages/LeafCore/Sources/LeafCore/Insights/Helpers/IDEFamilyClassifier.swift`:

```swift
public static let terminalFamilyBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "com.warp.Warp",
    "io.alacritty",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "co.zeit.hyperterm",
]
```

Doc-comment explains: "Used by Claude Code Terminal-only workflow attribution. Per Track-10 Phase B (GUN-B 2026-05-23), hoisted from moat-private `static let` for cross-extension reuse."

### 3.2 Public LeafCore — `SessionSource` enum + `CurrentTaskSession` field

`Packages/LeafCore/Sources/LeafCore/Insights/CurrentTaskSession.swift`:

```swift
public enum SessionSource: String, Sendable, Equatable, Codable {
    case ide
    case aiCollaboration
    case fallback
}
```

Add field to `CurrentTaskSession`:
```swift
public let sessionSource: SessionSource

public init(
    taskIdentity: TaskIdentity,
    sessionStartMs: Int64,
    focusedMinSoFar: Int,
    openFiles: [String],
    sessionSource: SessionSource = .fallback  // 15th defaulted-init iteration
) { ... }
```

Update Equatable / Hashable / Sendable conformances (auto via stored property).

### 3.3 YoureOnRowComposer — sessionSource-aware session line

`Packages/LeafCore/Sources/LeafCore/Home/YoureOnRowComposer.swift`:

```swift
public static func composeSessionLine(
    sessionStartMs: Int64,
    focusedMin: Int,
    sessionSource: SessionSource = .fallback,
    now: Date,
    calendar: Calendar
) -> String? {
    let startLabel = formatSessionStart(sessionStartMs: sessionStartMs, now: now, calendar: calendar)
    let focusLabel = formatFocusedMin(focusedMin)
    var line = "Started \(startLabel)"
    if let focus = focusLabel { line += " · \(focus) focused so far" }
    if sessionSource == .aiCollaboration { line += " via Claude Code" }
    return line
}
```

Backward-compat: existing callsites that don't pass `sessionSource` get `.fallback` default → no suffix.

### 3.4 YoureOnBlock view — thread sessionSource

`Leaf/Views/Window/Home/Blocks/YoureOnBlock.swift`:

```swift
YoureOnRowComposer.composeSessionLine(
    sessionStartMs: session.sessionStartMs,
    focusedMin: session.focusedMinSoFar,
    sessionSource: session.sessionSource,   // ← new pass-through
    now: now, calendar: calendar)
```

### 3.5 Moat — symmetric compare-by-latestTs + sessionSource population (gitignored)

`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+CurrentTaskSession.swift`:

Refactor `perIDEEarliestEventTodayMatchingWorkspace`:
- Compute `ideCandidate: (earliestTs: Int64, latestTs: Int64, bundleIDs: [String])?`
- Compute `aiCandidate: (earliestTs: Int64, latestTs: Int64, bundleIDs: [String])?`
- Pick winner by `latestTs DESC`. Ties → IDE preferred (legacy behavior).
- Return `(sessionStartMs: Int64, dwellBundleIDs: [String], source: SessionSource)`.

Update `currentTaskSession()` to populate `sessionSource` from winning candidate. Delete moat-private `terminalFamilyBundleIDs`; reference `IDEFamilyClassifier.terminalFamilyBundleIDs`.

### 3.6 Sentinel-injection test (moat, gitignored)

`Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsCurrentTaskSessionSentinelTests.swift`:

```swift
func test_currentTaskSession_AICwdSentinelDoesNotLeak() throws {
    let sentinel = "LEAKED_SENTINEL_PHASE_B_AI_CWD_/Users/secret/leaked-workspace-path"
    // Insert aiCollaboration event with cwd = sentinel matching no workspace
    // Insert IDE attention event matching real workspace
    // Run currentTaskSession()
    // Assert:
    //   - taskIdentity.workspacePath == nil (D-8 invariant)
    //   - taskIdentity.branch does NOT contain sentinel
    //   - openFiles array does NOT contain sentinel
    //   - sessionSource == .ide (real IDE event present)
}

func test_currentTaskSession_AICwdMatchPathBytesNeverEscape() throws {
    let sentinel = "/Users/secret/sentinel-cwd-workspace"
    // Insert aiCollaboration event with cwd matching workspace (sentinel path)
    // Run currentTaskSession() — sessionSource should be .aiCollaboration
    // Assert sentinel never appears in:
    //   - taskIdentity.workspacePath
    //   - openFiles
    //   - any returned string
    //   - sessionSource == .aiCollaboration (the AI path won)
}
```

---

## 4. Acceptance gates

1. **AC-B1** — 5/5 xcodebuild Debug schemes SUCCESS.
2. **AC-B2** — SPM tests green (XCTest + Swift Testing), +2 new sentinel tests pass (LeafCorePrivateTests). Pre-existing flake exception clause applies.
3. **AC-B3** — `just check-tokens` 3-tier clean.
4. **AC-B4** — Privacy walkback: 0 hits across Phase B scope.
5. **AC-B5** — Sentinel-injection tests green (Phase B adds 2 new tests; T2 / T5 / T7 sentinels preserved).
6. **AC-B6** — HomeView 205 / HomeContent 151 preserved.
7. **AC-B7** — Substrate diff vs dev: 0 SQLCipher / 0 ShareEventTypeRegistry / 0 LeafMCP delta. CurrentTaskSession grows 1 field (defaulted) — backward-compat verified.
8. **AC-B8** — Master spec §9.2 carries T7H1/H2/H3 marked RESOLVED Phase B.
9. **AC-B9** — Manual smoke: YOU'RE ON renders "Started HH:MM · Nm focused so far" without "via Claude Code" suffix when IDE-anchored; with suffix when Claude Code Terminal-only workflow active and AI candidate latestTs > IDE candidate latestTs.

---

## 5. Carries after Phase B

| Carry | Status |
|---|---|
| C-T10-EMIT-T7H1 | RESOLVED Phase B (hardcoded `["LEAF", "GUN"]` shipped; v1.1 LinearIDPrefixCache deferred) |
| C-T10-EMIT-T7H2 | RESOLVED Phase B (aiCollaboration cwd fallback + symmetric compare-by-latestTs + sessionSource enum) |
| C-T10-EMIT-T7H3 | RESOLVED Phase B (`IDEFamilyClassifier.terminalFamilyBundleIDs` hoist + sentinel test) |
| C-25 | OPEN — Phase C |
| C-T10-EMIT-FLAKE | OPEN — separate triage |
| C-T10-EMIT-STANDUP-HOURS | OPEN — v1.1 |
| C-T10-EMIT-MCP-STANDUP | OPEN — future |
| C-T10-EMIT-LOC-RESUMEHERO | OPEN — informational tracker |
| LinearIDPrefixCache v1.1 | OPEN — multi-workspace onboarding trigger |

---

## 6. Files touched

**Created:**
- `docs/superpowers/specs/2026-05-23-track-10-phase-B-claude-code-firstclass.md`

**Modified (public):**
- `Packages/LeafCore/Sources/LeafCore/Insights/Helpers/IDEFamilyClassifier.swift` (+ terminalFamilyBundleIDs)
- `Packages/LeafCore/Sources/LeafCore/Insights/CurrentTaskSession.swift` (+ SessionSource enum + field)
- `Packages/LeafCore/Sources/LeafCore/Home/YoureOnRowComposer.swift` (composeSessionLine sessionSource param)
- `Leaf/Views/Window/Home/Blocks/YoureOnBlock.swift` (sessionSource pass-through)
- `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` (§9.2 RESOLVED markers)
- `.claude/shared/current-state.md` (Phase B landed)

**Modified (moat, gitignored):**
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+CurrentTaskSession.swift`
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsCurrentTaskSessionSentinelTests.swift` (new)

---

## 7. Workflow

1. ✅ Discovery — moat already has T7H1/H2/H3 fixes landed; IDEFamilyClassifier exists.
2. ✅ Brainstorm — D-B1..D-B7; brainstorm gate user-resolved (AI wins if more recent).
3. ✅ Spec write — this file.
4. ✅ Plan write — atomic commits per §3.
5. **NEXT**: Implementation — sequential atomic commits.
6. **NEXT**: Independent review — light a11y subagent re-pass (small UI diff).
7. **NEXT**: Verification — 9 AC gates per §4.
8. **NEXT**: Ship — SHIPPED commit + FF merge to collective.
