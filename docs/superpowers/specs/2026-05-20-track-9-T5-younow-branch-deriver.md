# Track-9 T5 — YOU·NOW branch deriver + rich enrichment UI

**Status:** SHIPPED — Stage 5 done. 3 moat helpers (WorkspacePathResolver / GitHeadReader / currentTaskIdentity rewrite) + YouNowFocus enrichment + YouNowBlock UI batch (label tweak + intensity hint + Resume CTA) + 22 net new tests (5 public + 1 sentinel + 16 moat). All 4 substrate-purity zero-diff invariants verified. 5/5 xcodebuild Debug schemes green. Privacy walkback narrow grep — 0 hits. `just check-tokens` 3-tier clean.
**Track-9 master design:** [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md) §T5 line 180-188.
**T1 spec (precedent — payload field landing pattern):** [`2026-05-19-track-9-T1-collector-payload-extensions.md`](./2026-05-19-track-9-T1-collector-payload-extensions.md).
**T4 spec (precedent — substrate-only deriver pattern):** [`2026-05-20-track-9-T4-weekly-metrics-deriver.md`](./2026-05-20-track-9-T4-weekly-metrics-deriver.md).
**Branch:** `feature/track-9-substrate` (off T4 wrap tip `3ded9e44` — T4 spec landing commit). FF после T5 acceptance.
**Ship classification:** **Hybrid — substrate + UI**. Pure-substrate phases (T1/T2/T3/T4) предыдущие были silent; T5 closes the loop visible to user: YOU·NOW `.active` line 2 finally renders `<contextLabel> · <branch> · <linearID>` per master spec §3 mockup. Zero new event_kinds / migrations / MCP tools / ShareEventTypeKey delta.

---

## 1. Scope

**In scope (all 6 master design §T5 deliverables in one session via 6 sub-agents):**

1. **`WorkspacePathResolver` standalone helper** в LeafCorePrivate moat (`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/WorkspacePathResolver.swift`, gitignored). Pure dispatch by `IDEFamilyClassifier.family(forBundleID:)`:
   - **Xcode** (`com.apple.dt.Xcode`) → read latest `xcode_active_doc_changed` event payload `doc_path` (absolute filesystem path).
   - **VSCode-family** (`VSCodeFamilyDispatcher.isVSCodeFamily`) → read latest `vscode_workspace_opened` event payload `workspace_root` (`~/`-prefixed sanitized path, gated by `LocalAppsStore.ideWorkspacePathTrackingEnabled`).
   - **JetBrains family** (`IDEFamilyClassifier.jetbrainsBundleIDs`) → read latest `jetbrains_recent_project_observed` event payload `workspace_root` (`~/`-prefixed sanitized path, same gate).
   - **Unknown / non-IDE** → return nil (fallback in caller).
2. **`GitHeadReader` pure helper** в LeafCorePrivate moat (`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/GitHeadReader.swift`, gitignored). Pure file-I/O, no DB. API `read(fromPath:) throws -> String?` (returns branch name or nil for detached HEAD / no `.git` / read failure).
   - Walks file path upward (max 20 ancestor levels) looking for `.git` (file or directory).
   - **Worktree case**: when `.git` is a regular file, parses `gitdir: <path>` pointer and dereferences to actual gitdir.
   - Reads `<gitdir>/HEAD` → if `ref: refs/heads/<name>` → returns `<name>`; if 40-char SHA → returns nil (detached HEAD).
   - **Tilde-prefixed input path** support — expands `~/...` to absolute path via `NSString.expandingTildeInPath` before walk (VSCode/JetBrains paths arrive sanitized).
3. **`currentTaskIdentity()` body rewrite** в `ProdInsights+CurrentTaskIdentity.swift` (LeafCorePrivate moat).
   - Stage 1: foreground bundle_id from `lastActivity(bundleID: nil)`.
   - Stage 2 (IDE-path branch): `WorkspacePathResolver.resolve(bundleID:db:)` → workspace path → `GitHeadReader.read(fromPath:)` → branch name (or nil for detached HEAD / no `.git` / resolver returned nil).
   - Stage 3 (window-title): ALWAYS read latest `window_title` for foreground bundle. Branch fallback when stage 2 yielded nil: `extractBranchToken(from: window_title)`. LinearID extracted from BOTH branch.uppercased() AND window_title.uppercased() (prefer branch match, fall back to window_title match) — preserves Phase 8.1 LinearID coverage for IDEs surfacing LEAF-N references in title.
   - `TaskIdentity.workspacePath` stays nil — T5 does NOT populate (reduces leak surface; T6+ можно если UI попросит).
4. **`YouNowFocus +branch +linearID` defaulted-init field additions** в `Packages/LeafCore/Sources/LeafCore/Insights/YouNowState.swift`. Mirror Track-9 T1 `YouNowAway.lastAppBundleID: String? = nil` precedent — trailing defaulted Optional params preserve all existing init callsites. `YouNowFocus` shape: `{ modeName, app, contextLabel, durationSec, branch: String? = nil, linearID: String? = nil }`.
5. **`YouNowStateDeriver` extension** — pipe `inputs.branch` + `inputs.linearID` into `.deepWorkFocus` case construction. Symmetric с `.active` branch (`YouNowActive(branch:linearID:)` уже populated Phase 8.4).
6. **UI surface changes в `Leaf/Views/Window/Home/Blocks/YouNowBlock.swift`:**
   - **`focusContent`** — extend `line2: [f.app, f.contextLabel, f.branch, f.linearID].compactMap.joined(" · ").nilIfEmpty`. Mirror `activeContent` line 2 shape.
   - **`activeTimeLine`** label tweak — `"Started 17:30 · 38m"` → `"\(formatDuration(...)) focused"` (matches mockup §3 wording `42 min focused`). Drops Started timestamp surface entirely — duration alone communicates session length.
   - **Intensity UX hint** — conditional view rendered below row when `s.intensityBars == 0 AND SystemObserversStore.intensityAggregatorEnabled == false` → small text link "Enable intensity monitoring" → taps `RouteCoordinator.pushSettingsSystemObservers()` (new convenience method or `AppRoute.settings(section: .systemObservers, sub: nil)`).
   - **`resumeCTA`** LinearID-aware label — when `lastLinearID != nil` → label substitutes to `"Resume \(lastLinearID)"` (e.g., `"Resume LEAF-204"`); else generic `"Resume"`. 4-gate eligibility preserved (lastAppBundleID + enabled + lastLinearID + idle≤24h).
7. **`RouteCoordinator.pushSettingsSystemObservers()`** convenience method (or equivalent if existing surface already routes there). Routes to `AppRoute.settings(section: .systemObservers, sub: nil)` per Track-7 P2 plumbing.
8. **`RelayBodyLeakageTests` sentinel-injection regression** — seed `xcode_active_doc_changed` event with `doc_path` containing sentinel string `LEAKED_SENTINEL_T5_DOCPATH`, run `currentTaskIdentity()` → assert NO sentinel substring leaks into `presence_state.state_json` for any provider key OR into events.payload_json for any newly-written row. Mirror Track-9 T1 `LEAKED_SENTINEL_VSCODE_USERNAME` pattern (sentinel injected at position which MUST NOT leak; in T5 the branch name DOES legitimately survive into TaskIdentity, but the workspace path bytes must not).

**Hard exclusion (out of T5 — carry list):**

- **Cached resolver with FSEvents invalidation** (Q2 Option B) — over-engineered for sub-ms fs walk. T5b or post-Track-9 if observed perf issues.
- **`git_branch_changed` capture-path event_kind** (Q2 Option C) — substrate purity broken. Not needed.
- **Multi-window VSCode/JetBrains foreground detection** — resolver returns latest opened workspace, NOT currently-foreground if user has multiple windows. Known limitation, document §1.1.
- **`TaskIdentity.workspacePath` population** — kept nil; T5 does not populate (reduces leak surface). T6+ if UI needs it.
- **Real-time `LinearIDPrefixCache` workspace whitelist** — T5 reuses existing Phase 8.1 hardcoded `["LEAF"]` set; v1.1 dynamic prefix cache out of scope.
- **Snapshot tests for YouNowBlock UI** — no Track-8 precedent; visual verification via manual smoke только.
- **T6 `topTools` SurfacePill refactor** — separate phase.
- **UI styling beyond functional changes** — typography / spacing / а11y polish carry to T10 wrap.

### 1.1 Deviations from Track-9 master spec §T5

Master spec §T5 line 181:
> `currentTaskIdentity()` per-IDE dispatch — Xcode reads `doc_path`, VSCode/JetBrains read `workspace_root` (T1 dep) → walks up to `.git/HEAD` → parses ref → `branch`.

T5 substrate fully delivers this. Two refinements relative к verbatim master wording:

**Refinement A — Window-title fallback preserved.** When `WorkspacePathResolver` returns nil (e.g., foreground bundle is Slack/Terminal/Browser, not an IDE; OR `LocalAppsStore.ideWorkspacePathTrackingEnabled = false` для VSCode/JetBrains; OR no recent IDE event in DB), `currentTaskIdentity()` falls back to existing Phase 8.1 `extractBranchToken` heuristic on `window_title`. Preserves backwards-compat: bundles that produced branch via window_title heuristic before T5 continue to do so.

**Refinement B — Multi-window known limitation.** `vscode_workspace_opened` / `jetbrains_recent_project_observed` events emit on workspace OPEN (FSEvents-driven), not on window focus switch. If user opens workspace A, then B, then switches back to A's window — resolver returns B (latest opened). Acceptable known limitation; full multi-window foreground tracking requires per-IDE AppleScript / AX plumbing outside T5 scope.

**Refinement C — `TaskIdentity.workspacePath` kept nil.** Master spec implicit но T5 explicit decision: substrate produces `branch` + `linearID` but NOT `workspacePath`. Reduces leak surface in the materialized TaskIdentity value (path stays in-memory for resolver call only). T6+ can populate if Analytics UI shows workspace breadcrumb.

**Refinement D — Worktree support in GitHeadReader.** Master spec wording `.git/HEAD` implies standard repo. T5 ships first-class git worktree handling: when `.git` is a regular file containing `gitdir: <path>`, reader dereferences to the actual gitdir and reads HEAD from there. Project uses worktrees (`.claude/worktrees/` per `current-state.md`), so this is real coverage, not theoretical.

**Refinement E — `ideWorkspacePathTrackingEnabled = false` graceful degrade.** When user disables IDE workspace tracking via Settings, VSCode/JetBrains workspace_root events stop emitting. Resolver returns nil → fallback (A) kicks in → branch resolution gracefully degrades to window_title heuristic. Documented in §1.1; user retains explicit control over path-bytes-to-DB surface area (Track-9 T1 ADR-010 walkback intent preserved).

Master spec §T5 to be amended в T10 wrap (refinements A-E).

---

## 2. Decisions taken (Stage 2 brainstorm output)

| # | Question | Decision | Rationale |
|---|---|---|---|
| D-1 | Scope split | **Full T5 master design** — all 6 deliverables in one session via 6 sub-agents (Substrate A+B + Focus enrichment C + Active/Away/Label/Intensity UI + Tests + Verify). | User selected "Full T5 в одной сессии через саб-агентов". Master spec §T5 treats it as single phase. |
| D-2 | Branch resolution strategy | **Per-tick fs walk** (stateless). `currentTaskIdentity()` walks file path → `.git/HEAD` each call. No cache, no FSEvents watcher, no new event_kind. | Mirror Track-9 T1 `recentLastCommit` per-tick SQL read precedent. Filesystem walk on foreground IDE switch = sub-millisecond cost. Stateless eliminates coherency edge cases. |
| D-3 | IDE dispatch placement | **`WorkspacePathResolver` standalone helper** в LeafCorePrivate moat. Pure dispatch на `IDEFamilyClassifier.family(forBundleID:)`, 3 cases + nil fallback. Testable в изоляции (mock DB protocol). | Sub-agent friendly — Agent 1 owns resolver in isolation. `currentTaskIdentity()` body (Agent 3) stays assembly-focused. Future IDE addition = single new case. |
| D-4 | `.deepWorkFocus` enrichment depth | **`branch + linearID` symmetric с YouNowActive** — +2 optional defaulted fields on `YouNowFocus`. Pipe through `YouNowStateDeriver`. UI extends `line2` compactMap-join pattern. NOT workspacePath (ugly absolute path, asymmetric с YouNowActive). | Mirror YouNowActive shape lock. UI rendering trivial 1-line `compactMap` extension. |
| D-5 | Intensity UX hint scope | **Full impl в T5** — SystemObserversStore read + conditional UI link + `RouteCoordinator.pushSettingsSystemObservers()` deep-link. Master spec line 185 explicit. | Bounded scope (~40 LOC). Sub-agent dispatchable as part of Agent 5 (UI batch). Closes the surface defined by mockup §3. |
| D-6 | `.away` Resume CTA polish | **LinearID-aware label substitution** — when `lastLinearID != nil` → label = `"Resume \(lastLinearID)"`, else generic `"Resume"`. 4-gate eligibility preserved. | Master spec "LinearID display refinement" wording matches. ~5 LOC change in `resumeCTA`. |
| D-7 | Tests strategy | **Comprehensive ~21-22 tests** — public types tests (YouNowFocus shape + deriver), moat unit tests (WorkspacePathResolver 6 + GitHeadReader 7 + currentTaskIdentity integration 3), 1 sentinel-injection regression. No UI snapshot tests (no Track-8 precedent). | Per-unit failure localization. Sub-agent friendly (Agents 1/2/3/4 each own ~5-7 tests their unit ships). |
| D-8 | TaskIdentity.workspacePath | **Stays nil** — T5 does NOT populate. Reduces materialized path leak surface. T6+ populate if Analytics UI breadcrumb needed. | Conservative default. Phase 8.1 nil-default preserved. |
| D-9 | Git worktree support | **First-class** — `.git` as file with `gitdir: <path>` pointer dereferenced inside GitHeadReader. ~5 LOC, real coverage (project uses worktrees per `.claude/worktrees/`). | Without this, every developer with worktree falls back to window_title heuristic — same broken state as before T5. |
| D-10 | Multi-window edge case | **Known limitation, documented.** Resolver returns latest opened workspace (per FSEvents emission), not currently-foreground if user has multiple IDE windows of same family. | Full foreground tracking requires per-IDE AppleScript / AX plumbing — substantial scope outside T5. Document как trade-off, не bug. |
| D-11 | Window-title fallback | **Preserved** — when resolver returns nil, existing Phase 8.1 `extractBranchToken` heuristic on window_title kicks in. | Backwards-compat invariant. Bundles that produced branch before T5 continue to do so. |
| D-12 | `ideWorkspacePathTrackingEnabled = false` | **Graceful degrade** — VSCode/JetBrains resolver returns nil → fallback A. Xcode unaffected (no toggle). | User toggle control over path-bytes-to-DB preserved (T1 ADR-010 walkback intent). |
| D-13 | label tweak format | **`"\(formatDuration(...)) focused"`** — reuse existing `formatDuration(TimeInterval)` helper. Sub-hour: `"42m focused"`; multi-hour: `"1h 23m focused"`. Drops `Started HH:MM` surface entirely. | Master mockup §3 explicit `42 min focused`. Reuse formatDuration matches existing YouNowBlock conventions. |
| D-14 | Intensity hint placement | **Below row layout** (not inside line 3) — separate `if shouldShowIntensityHint` view rendered below `rowLayout` in `activeContent`. Small `Button(role: .none)` with text `"Enable intensity monitoring"` style `LeafType.body.small`, foreground `LeafColor.text.tertiary`, underline on hover. | Below-row placement avoids cluttering line 3 (intensity bars already there when bars > 0). Discoverable but unobtrusive. |
| D-15 | RouteCoordinator method | **`pushSettingsSystemObservers()`** new convenience — wraps `pushHomeAnalytics`-style routing to `AppRoute.settings(section: .systemObservers, sub: nil)`. Sibling helpers exist Track-7 P2. | Convention parity. Single callsite from intensity hint Button. |
| D-16 | Sub-agent decomposition | **6 sequential agents** (Agents 1+2 parallel-dispatched single message; Agents 3-6 sequential review-between). | Agents 1+2 fully independent files (resolver / git reader). Agent 3 needs both. Agent 4 (YouNowFocus +fields + UI focusContent) standalone. Agent 5 (UI batch label/intensity/away + RouteCoordinator) ships after Agent 4 to avoid YouNowBlock merge conflict. Agent 6 (main or sub) sentinel-injection + verify. |
| D-17 | Sentinel test placement | **`Packages/LeafCore/Tests/LeafCoreTests/Privacy/RelayBodyLeakageTests.swift`** extend (existing test suite). Sentinel `LEAKED_SENTINEL_T5_DOCPATH` injected into `doc_path` payload field of seeded `xcode_active_doc_changed` event. | Mirror Track-9 T1 sentinel pattern. Single test, locks invariant "path-bytes never leak into presence_state OR new events". |
| D-18 | Tests split: public vs moat | **Public** (`LeafCoreTests`): YouNowFocus shape + deriver focus enrichment + sentinel regression. **Moat** (`LeafCorePrivateTests`): WorkspacePathResolver + GitHeadReader + currentTaskIdentity integration. | T1/T3/T4 precedent. SQL/fs operations stay in moat; type contracts public. |
| D-19 | Branch off | **`feature/track-9-substrate` at T4 wrap tip `3ded9e44`** (T4 spec landing commit). FF after T5 acceptance. | Mirror T4-off-T3 chain. T5..T10 sequence on same collective branch. |

---

## 3. Architecture

### 3.1 Component map

```
LeafCore (public)
├── Insights/YouNowState.swift                   (MODIFY — +branch +linearID on YouNowFocus)
│   └── YouNowFocus { modeName, app, contextLabel, durationSec, branch?, linearID? }
│
├── Insights/YouNowStateDeriver.swift            (MODIFY — pipe branch/linearID to .deepWorkFocus)
│
LeafCorePrivate (moat, gitignored)
├── Prod/Insights/WorkspacePathResolver.swift    (NEW)
│   └── enum WorkspacePathResolver
│       └── static func resolve(bundleID:db:) throws -> String?
│           ├── Xcode → SELECT json_extract(payload_json, '$.doc_path') FROM events
│           │            WHERE signal_type='attention' AND bundle_id='com.apple.dt.Xcode'
│           │              AND json_extract(payload_json, '$.event_kind')='xcode_active_doc_changed'
│           │            ORDER BY ts DESC LIMIT 1
│           ├── VSCode-family → SELECT json_extract(payload_json, '$.workspace_root') FROM events
│           │                    WHERE bundle_id IN (VSCodeFamilyDispatcher.allBundleIDs)
│           │                      AND json_extract(payload_json, '$.event_kind')='vscode_workspace_opened'
│           │                    ORDER BY ts DESC LIMIT 1
│           ├── JetBrains → SELECT json_extract(payload_json, '$.workspace_root') FROM events
│           │                WHERE bundle_id IN IDEFamilyClassifier.jetbrainsBundleIDs
│           │                  AND json_extract(payload_json, '$.event_kind')='jetbrains_recent_project_observed'
│           │                ORDER BY ts DESC LIMIT 1
│           └── unknown / no event → nil
│
├── Prod/Insights/GitHeadReader.swift            (NEW)
│   └── enum GitHeadReader
│       ├── static func read(fromPath:) throws -> String?
│       │   ├── expand ~/ → absolute via NSString.expandingTildeInPath
│       │   ├── walk upward (max 20 levels) seeking .git (file or directory)
│       │   ├── if .git is file → parse 'gitdir:' pointer → dereference
│       │   ├── read <gitdir>/HEAD
│       │   ├── if content starts 'ref: refs/heads/' → return branch name
│       │   └── if 40-char SHA → nil (detached HEAD)
│       └── internal helpers: walkUpward / readGitdirPointer / parseHead
│
├── Prod/Insights/ProdInsights+CurrentTaskIdentity.swift   (REWRITE body)
│   └── public func currentTaskIdentity() throws -> TaskIdentity?
│       ├── frontmost = lastActivity(bundleID: nil)
│       ├── workspacePath = WorkspacePathResolver.resolve(bundleID: frontmost.bundleID, db:)
│       ├── if workspacePath != nil:
│       │   ├── branch = GitHeadReader.read(fromPath: workspacePath)
│       │   └── linearID = LinearIDExtractor.extract(text: branch.uppercased(), knownPrefixes:)
│       ├── if branch == nil (resolver returned nil OR git reader failed):
│       │   └── windowTitle = readLastWindowTitle(forBundle:) // existing fallback
│       │       ├── branch = extractBranchToken(from: windowTitle)
│       │       └── linearID = LinearIDExtractor.extract(text: windowTitle.uppercased(), …)
│       └── return TaskIdentity(linearID:, branch:, repo: nil, workspacePath: nil)
│
├── Prod/Insights/ProdInsights+YouNowState.swift  (MODIFY — pipe branch/linearID to focus inputs)
│   └── identity.branch / identity.linearID populated → derive .deepWorkFocus carries them

Leaf (public app UI)
├── Views/Window/Home/Blocks/YouNowBlock.swift   (MODIFY — 4 changes)
│   ├── activeContent → activeTimeLine returns "\(formatDuration(...)) focused"
│   ├── activeContent → conditional intensity hint view below row
│   ├── focusContent → line 2 = [f.app, f.contextLabel, f.branch, f.linearID].compactMap.joined(" · ")
│   └── awayContent / resumeCTA → label substitution "Resume \(lastLinearID)" when present
│
├── Routing/RouteCoordinator.swift               (MODIFY — +pushSettingsSystemObservers)
│   └── public func pushSettingsSystemObservers() { route to AppRoute.settings(section:sub:) }
```

### 3.2 Data flow

```
Tick (every 1-2s during foreground via InsightsReader.refresh()):

1. youNowState(now:) — Prod moat
   ├── currentTaskIdentity()
   │   ├── lastActivity → frontmost bundle_id
   │   ├── WorkspacePathResolver.resolve(bundleID:) → workspace_path (or nil)
   │   ├── if workspace_path → GitHeadReader.read(fromPath:) → branch
   │   ├── if branch nil → fallback extractBranchToken(window_title)
   │   ├── linearID = LinearIDExtractor.extract(branch.uppercased() OR window_title.uppercased())
   │   └── return TaskIdentity(branch:, linearID:, repo: nil, workspacePath: nil)
   ├── build YouNowInputs(branch: identity?.branch, linearID: identity?.linearID, …)
   └── YouNowStateDeriver.derive(inputs) → YouNowState
       ├── .active(YouNowActive(branch:, linearID:, …)) — Phase 8.4 already populated
       └── .deepWorkFocus(YouNowFocus(branch:, linearID:, …)) — T5 NEW pipe

2. InsightsReader stores YouNowState in InsightsSnapshot.youNowState
3. HomeView passes snapshot.youNowState to YouNowBlock
4. YouNowBlock renders:
   ├── .active → line 1 app · line 2 contextLabel·branch·linearID · line 3 "X min focused" + intensity bars
   ├── .deepWorkFocus → line 1 "Deep work: <mode>" · line 2 app·contextLabel·branch·linearID · line 3 duration
   ├── .inMeeting (unchanged)
   └── .away → line 1 reason · line 2 lastApp·context · line 3 idle · Resume CTA "Resume <linearID>" or "Resume"

Filesystem side (per currentTaskIdentity call):
   stat(/path/to/file.swift) → stat(/path/to) → stat(/path) → ... up to .git
   ├── if .git is dir → read .git/HEAD
   └── if .git is file → parse "gitdir: <path>" → read <path>/HEAD
   Parse HEAD content → branch name OR detached SHA OR error
```

### 3.3 `WorkspacePathResolver` API + per-IDE SQL

```swift
/// MOAT — Track-9 T5 — IDE family dispatch for current workspace path.
/// Pure dispatch on IDEFamilyClassifier.family(forBundleID:). Returns nil
/// for unknown/non-IDE bundles OR when family-specific event not present
/// in recent DB history.
///
/// Multi-window edge case: when user has multiple IDE windows of same
/// family open, resolver returns LATEST opened workspace path (per
/// FSEvents-driven emission), not necessarily the currently-foreground
/// window. Acceptable known limitation; full foreground tracking requires
/// per-IDE AppleScript/AX plumbing outside T5 scope.
internal enum WorkspacePathResolver {
    /// Returns workspace path for the given bundleID using the most recent
    /// relevant event in DB. Path is returned as-stored:
    ///   - Xcode → absolute (e.g., `/Users/me/Desktop/Leaf/leaf/.../Foo.swift`)
    ///   - VSCode-family → tilde-prefixed (e.g., `~/Desktop/Leaf/leaf`)
    ///   - JetBrains → tilde-prefixed
    /// GitHeadReader expands tilde internally before fs walk.
    internal static func resolve(bundleID: String, db: Database) throws -> String? {
        switch IDEFamilyClassifier.family(forBundleID: bundleID) {
        case .vscodeFamily:
            return try fetchVSCodeWorkspaceRoot(db: db, bundleID: bundleID)
        case .jetbrains:
            return try fetchJetBrainsWorkspaceRoot(db: db, bundleID: bundleID)
        case .fallback:
            // Xcode is `.fallback` because IDEFamilyClassifier doesn't have an .xcode case.
            // Resolver dispatches Xcode by explicit bundle_id check inside fetchXcodeDocPath.
            return try fetchXcodeDocPath(db: db, bundleID: bundleID)
        }
    }

    private static func fetchXcodeDocPath(db: Database, bundleID: String) throws -> String? {
        guard bundleID == "com.apple.dt.Xcode" else { return nil }
        return try db.readSQL { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT json_extract(payload_json, '$.doc_path')
                    FROM events
                    WHERE signal_type = 'attention'
                      AND bundle_id = ?
                      AND json_extract(payload_json, '$.event_kind') = 'xcode_active_doc_changed'
                      AND json_extract(payload_json, '$.doc_path') IS NOT NULL
                    ORDER BY ts DESC
                    LIMIT 1
                    """,
                arguments: [bundleID]
            )
        }
    }

    private static func fetchVSCodeWorkspaceRoot(db: Database, bundleID: String) throws -> String? {
        // Cross-bundle query — VSCode-family includes Code/Cursor/Insiders/VSCodium.
        // workspace_root event emits per-workspace-OPEN regardless of which family
        // bundle is foreground; we filter to the foreground family member's events
        // when possible, but accept cross-family overlap (Code+Cursor share repos).
        let familyBundles = VSCodeFamilyDispatcher.allBundleIDs
        guard familyBundles.contains(bundleID) else { return nil }
        return try db.readSQL { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT json_extract(payload_json, '$.workspace_root')
                    FROM events
                    WHERE bundle_id IN (\(placeholders(for: familyBundles)))
                      AND json_extract(payload_json, '$.event_kind') = 'vscode_workspace_opened'
                      AND json_extract(payload_json, '$.workspace_root') IS NOT NULL
                    ORDER BY ts DESC
                    LIMIT 1
                    """,
                arguments: StatementArguments(familyBundles)
            )
        }
    }

    private static func fetchJetBrainsWorkspaceRoot(db: Database, bundleID: String) throws -> String? {
        guard IDEFamilyClassifier.jetbrainsBundleIDs.contains(bundleID) else { return nil }
        let bundles = IDEFamilyClassifier.jetbrainsBundleIDs
        return try db.readSQL { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT json_extract(payload_json, '$.workspace_root')
                    FROM events
                    WHERE bundle_id IN (\(placeholders(for: bundles)))
                      AND json_extract(payload_json, '$.event_kind') = 'jetbrains_recent_project_observed'
                      AND json_extract(payload_json, '$.workspace_root') IS NOT NULL
                    ORDER BY ts DESC
                    LIMIT 1
                    """,
                arguments: StatementArguments(Array(bundles))
            )
        }
    }

    private static func placeholders(for collection: any Collection) -> String {
        Array(repeating: "?", count: collection.count).joined(separator: ", ")
    }
}
```

### 3.4 `GitHeadReader` API + worktree dereferencing

```swift
/// MOAT — Track-9 T5 — pure file-I/O helper to extract git branch from a path.
/// Walks upward to find .git (file or directory). Handles git worktrees
/// where .git is a regular file containing `gitdir: <path>` pointer to the
/// actual gitdir. Returns nil for detached HEAD, no .git, or read failure.
///
/// Tilde-prefixed input paths (~/...) expanded internally before walk.
///
/// Bounded walk: max 20 ancestor levels to prevent pathological cases
/// (e.g., path on remote-mounted FS / circular symlinks).
internal enum GitHeadReader {
    private static let maxWalkDepth = 20

    /// Returns the branch name extracted from `<gitdir>/HEAD`, or nil if:
    ///   - path not absolute after tilde expansion
    ///   - no `.git` found within maxWalkDepth ancestors
    ///   - HEAD content is a SHA (detached HEAD)
    ///   - HEAD file read fails (permissions, missing, malformed)
    internal static func read(fromPath path: String) throws -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        guard let gitdir = locateGitdir(startingAt: expanded) else { return nil }
        return try parseHead(at: gitdir + "/HEAD")
    }

    /// Walks upward from `start` looking for `.git` entry. Returns the
    /// resolved gitdir path (directory containing HEAD).
    private static func locateGitdir(startingAt start: String) -> String? {
        var current = start
        for _ in 0..<maxWalkDepth {
            let dotGit = current + "/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if isDir.boolValue {
                    return dotGit
                }
                // .git is a regular file — parse `gitdir: <path>` pointer.
                if let pointer = readGitdirPointer(fromFile: dotGit) {
                    return pointer
                }
                return nil
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
        return nil
    }

    /// Parses `.git` file content like `gitdir: /path/to/main/.git/worktrees/<name>`.
    /// Returns the dereferenced gitdir path, or nil on malformed content.
    private static func readGitdirPointer(fromFile path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gitdir: ") {
                return String(trimmed.dropFirst("gitdir: ".count))
            }
        }
        return nil
    }

    /// Parses HEAD file content. Returns branch name from `ref: refs/heads/<name>`,
    /// or nil for detached HEAD (40-char SHA) / malformed content.
    private static func parseHead(at path: String) throws -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        // 40-char hex = detached HEAD
        if trimmed.count == 40, trimmed.allSatisfy({ $0.isHexDigit }) {
            return nil
        }
        return nil
    }
}
```

### 3.5 `currentTaskIdentity()` rewrite

```swift
public func currentTaskIdentity() throws -> TaskIdentity? {
    guard let last = try lastActivity(bundleID: nil) else { return nil }
    let bundleID = last.bundleID
    let knownPrefixes: Set<String> = ["LEAF"]

    // Stage 1+2 — IDE-aware branch path: WorkspacePathResolver → GitHeadReader.
    let workspacePath = try WorkspacePathResolver.resolve(bundleID: bundleID, db: database)
    let branchFromGit: String? = try workspacePath.flatMap { path in
        try GitHeadReader.read(fromPath: path)
    }

    // Stage 3 — Window-title read (ALWAYS, not gated on branchFromGit).
    // Window title is a dual-source for LinearID extraction (Cursor/Code window
    // titles often contain "LEAF-N" references separately from branch), and the
    // fallback source for branch when git resolution fails.
    let windowTitle = try readLastWindowTitle(forBundle: bundleID)

    // Branch resolution — prefer git source, fall back to window_title heuristic.
    let branch = branchFromGit ?? windowTitle.flatMap { extractBranchToken(from: $0) }

    // LinearID extraction — try branch first (highest signal), fall back to
    // window_title text (preserves Phase 8.1 behavior where IDEs that don't
    // surface branch in title still leak LEAF-N references through filename
    // or tab subtitle).
    let linearIDFromBranch = branch.flatMap {
        LinearIDExtractor.extract(text: $0.uppercased(), knownPrefixes: knownPrefixes)
    }
    let linearIDFromTitle = windowTitle.flatMap {
        LinearIDExtractor.extract(text: $0.uppercased(), knownPrefixes: knownPrefixes)
    }
    let linearID = linearIDFromBranch ?? linearIDFromTitle

    return TaskIdentity(
        linearID: linearID,
        branch: branch,
        repo: nil,
        workspacePath: nil  // T5: kept nil per D-8
    )
}
```

### 3.6 `YouNowFocus +branch +linearID`

```swift
public struct YouNowFocus: Equatable, Hashable, Sendable {
    public let modeName: String?
    public let app: String?
    public let contextLabel: String?
    public let durationSec: Int
    public let branch: String?      // Track-9 T5 — NEW
    public let linearID: String?    // Track-9 T5 — NEW

    public init(
        modeName: String?, app: String?, contextLabel: String?, durationSec: Int,
        branch: String? = nil, linearID: String? = nil
    ) {
        self.modeName = modeName
        self.app = app
        self.contextLabel = contextLabel
        self.durationSec = durationSec
        self.branch = branch
        self.linearID = linearID
    }
}
```

Trailing defaulted params preserve all existing init callsites (mirror Track-9 T1 `lastAppBundleID: String? = nil` precedent).

`YouNowStateDeriver` extension — when constructing `.deepWorkFocus`, pass `branch: inputs.branch, linearID: inputs.linearID`.

### 3.7 UI changes

**`activeContent` label tweak (D-13):**
```swift
private func activeTimeLine(_ s: YouNowActive) -> String {
    "\(formatDuration(TimeInterval(s.durationSec))) focused"
}
```

**`focusContent` line 2 extension (D-4):**
```swift
private func focusContent(_ f: YouNowFocus) -> some View {
    rowLayout(
        // ... existing fields ...
        line2: [f.app, f.contextLabel, f.branch, f.linearID]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
        line3: formatDuration(TimeInterval(f.durationSec)),
        trailingBars: 0
    )
}
```

**`activeContent` intensity hint (D-5):**
```swift
private func activeContent(_ s: YouNowActive) -> some View {
    VStack(alignment: .leading, spacing: LeafSpace.sm) {
        rowLayout(/* existing */)
        if shouldShowIntensityHint(s) {
            intensityHintLink
        }
    }
}

private func shouldShowIntensityHint(_ s: YouNowActive) -> Bool {
    s.intensityBars == 0 && !systemObserversStore.intensityAggregatorEnabled
}

private var intensityHintLink: some View {
    Button {
        routeCoordinator.pushSettingsSystemObservers()
    } label: {
        Text("Enable intensity monitoring")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
            .underline()
    }
    .buttonStyle(.plain)
    .accessibilityHint("Opens Settings to enable intensity monitoring")
}
```

**`resumeCTA` LinearID-aware label (D-6):**
```swift
private func resumeCTA(for a: YouNowAway) -> some View {
    let label: String = a.lastLinearID.map { "Resume \($0)" } ?? "Resume"
    return Button { handleResume(a) } label: { Text(label) }
        // ... existing styling, accessibility ...
}
```

### 3.8 `RouteCoordinator.pushSettingsSystemObservers()`

```swift
// In RouteCoordinator (Leaf/Routing/RouteCoordinator.swift)
public func pushSettingsSystemObservers() {
    // Route to AppRoute.settings(section: .systemObservers, sub: nil)
    // (exact API matches Track-7 P2 plumbing — verify settings deep-link
    // signature when implementing)
    push(.settings(section: .systemObservers, sub: nil))
}
```

---

## 4. Acceptance criteria

| # | Criterion | Verification |
|---|---|---|
| AC-1 | `WorkspacePathResolver` returns correct path for Xcode bundle / VSCode bundle / JetBrains bundle / unknown bundle / no events | 6 moat tests pass |
| AC-2 | `GitHeadReader` correctly parses `ref: refs/heads/<branch>` / detached HEAD SHA (returns nil) / no `.git` (returns nil) / walks upward / worktree `.git` file dereferenced via `gitdir:` pointer / tilde-prefixed input expanded / empty HEAD file (returns nil) | 7 moat tests pass |
| AC-3 | `currentTaskIdentity()` integration: Xcode foreground with `doc_path` → branch resolved from `.git/HEAD` / VSCode foreground with `workspace_root` → branch resolved / JetBrains same / non-IDE foreground → window_title fallback kicks in | 3 moat integration tests pass |
| AC-4 | `YouNowFocus.branch` + `.linearID` defaulted-init fields exist; Equatable round-trip preserved; `YouNowStateDeriver` pipes them to `.deepWorkFocus` | 4 public tests pass |
| AC-5 | YOU·NOW `.active` line 2 mockup-fidelity render in real Mac smoke: `Xcode · Foo.swift · feature/branch · LEAF-N` | Manual smoke per master spec §3 mockup |
| AC-6 | YOU·NOW `.deepWorkFocus` line 2 includes branch + linearID when detectable | Manual smoke / UI compile |
| AC-7 | `.active` line 3 = `"X min focused"` format (not `"Started HH:MM · Xm"`) | Manual smoke / UI compile |
| AC-8 | Intensity hint renders when `intensityBars == 0 AND intensityAggregatorEnabled == false`; tap opens Settings → System Observers section | Manual smoke |
| AC-9 | Resume CTA label = `"Resume LEAF-204"` when `lastLinearID = "LEAF-204"`; generic `"Resume"` else; 4-gate eligibility preserved | Manual smoke / UI compile |
| AC-10 | Sentinel-injection: `doc_path` containing `LEAKED_SENTINEL_T5_DOCPATH` does NOT appear in `presence_state.state_json` for any provider OR in `events.payload_json` for any newly-written row after `currentTaskIdentity()` runs | 1 public sentinel test pass |
| AC-11 | 5/5 xcodebuild Debug schemes (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP) BUILD SUCCEEDED | Each scheme compiles clean |
| AC-12 | Net new test count ~22 (4 public YouNowFocus/deriver + 1 public sentinel + 6 moat resolver + 7 moat git reader + 3 moat integration + 1 spec status) | Post-T5 SPM = T4 baseline 2926 + ~22 = ~2948 |
| AC-13 | Zero new SQLCipher migrations | `git diff <T4-tip> -- Packages/LeafCore/Sources/LeafCore/DB/` empty |
| AC-14 | Zero new MCP tools | `git diff <T4-tip> -- LeafMCP/ Packages/LeafCore/Sources/LeafCore/MCP/` empty |
| AC-15 | Zero ShareEventTypeKey delta (registry frozen at 198) | `git diff <T4-tip> -- Packages/LeafCore/Sources/LeafCore/Privacy/ShareEventTypeKey.swift Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` empty |
| AC-16 | `GitHeadReader` correctly dereferences `.git` as a file (worktree case) — parses `gitdir: <path>` pointer and reads HEAD from the actual gitdir | Dedicated worktree-fixture moat test passes |
| AC-17 | Non-IDE foreground bundle (e.g., Slack at `com.tinyspeck.slackmacgap`) falls back to existing `extractBranchToken` window_title heuristic — no regression vs Phase 8.1 behavior | 1 moat integration test pass (Slack fixture w/ window_title containing branch token) |
| AC-18 | Privacy walkback narrow grep on T5 file scope → 0 hits | `grep -nE "absolute_path\|full_comment_body\|raw_email\|notes_body\|email_subject\|note_body\|file_contents\|raw_prompt\|tool_input\|tool_response\|response_body"` returns empty on T5-touched files |
| AC-19 | `just check-tokens` 3-tier clean | exit 0 |
| AC-20 | Spec self-review clean (no TBD / TODO / placeholder; no contradicting decisions) | Manual pass before plan write |

---

## 5. Tests

### 5.1 Public tests (`LeafCoreTests`)

**`Packages/LeafCore/Tests/LeafCoreTests/Insights/YouNowFocusEnrichmentTests.swift`** (NEW):

| Test | Asserts |
|---|---|
| `testYouNowFocusEquatableRoundTrip` | Init with all fields + Equatable + identity |
| `testYouNowFocusDefaultedInitPreservesExistingCallsites` | Init without branch/linearID compiles + defaults to nil |
| `testYouNowFocusBranchLinearIDFieldsHashable` | Hashable contract via Set membership |

**`Packages/LeafCore/Tests/LeafCoreTests/Insights/YouNowStateDeriverFocusEnrichmentTests.swift`** (NEW):

| Test | Asserts |
|---|---|
| `testDeriverPipesBranchAndLinearIDToDeepWorkFocus` | YouNowInputs(branch:linearID:focusActive:true) → derive returns .deepWorkFocus carrying both |
| `testDeriverEmptyBranchYieldsNilOnFocus` | Inputs with nil branch → .deepWorkFocus.branch == nil |

Total **5 public tests**.

**`Packages/LeafCore/Tests/LeafCoreTests/Privacy/RelayBodyLeakageTests.swift`** EXTEND:

| Test | Asserts |
|---|---|
| `testTaskIdentityResolverDoesNotLeakDocPathIntoPresenceStateOrEvents` | Seed `xcode_active_doc_changed` event with `doc_path` containing `"/Users/LEAKED_SENTINEL_T5_DOCPATH/Desktop/repo/Foo.swift"`. Run `currentTaskIdentity()`. Assert: (1) no row in `presence_state` contains sentinel substring in any state_json field; (2) no newly-written events row contains sentinel substring outside the seeded event's payload. |

Total **1 sentinel test**.

### 5.2 Moat tests (`LeafCorePrivateTests`)

**`Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/WorkspacePathResolverTests.swift`** (NEW):

| Test | Asserts |
|---|---|
| `testResolveXcodeBundleReturnsLatestDocPath` | Seed 2 `xcode_active_doc_changed` events with `doc_path` "/Users/me/A.swift" (older) + "/Users/me/B.swift" (newer). Resolve "com.apple.dt.Xcode" → "/Users/me/B.swift" |
| `testResolveVSCodeBundleReturnsLatestWorkspaceRoot` | Seed `vscode_workspace_opened` event with `workspace_root="~/Desktop/Leaf/leaf"` for bundle "com.microsoft.VSCode". Resolve "com.microsoft.VSCode" → "~/Desktop/Leaf/leaf" |
| `testResolveJetBrainsBundleReturnsLatestWorkspaceRoot` | Seed `jetbrains_recent_project_observed` event for "com.jetbrains.intellij". Resolve → workspace_root value |
| `testResolveCursorBundleSharesVSCodeFamilyQuery` | Seed VSCode workspace event for "com.microsoft.VSCode", resolve "com.todesktop.230313mzl4w4u92" (Cursor). Cross-family query returns same workspace_root |
| `testResolveUnknownBundleReturnsNil` | Resolve "com.tinyspeck.slackmacgap" → nil |
| `testResolveNoEventsReturnsNil` | Empty DB → resolve for Xcode bundle → nil |

Total **6 moat tests**.

**`Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/GitHeadReaderTests.swift`** (NEW):

| Test | Asserts |
|---|---|
| `testReadStandardRepoReturnsBranch` | Temp dir fixture with `.git/HEAD` content `"ref: refs/heads/main\n"`. Read from temp_dir/sub/Foo.swift → "main" |
| `testReadDetachedHEADReturnsNil` | `.git/HEAD` content = 40-char SHA → nil |
| `testReadNoGitReturnsNil` | Temp dir without `.git` → nil |
| `testReadWalkUpwardFindsAncestor` | Temp dir / src / app / file.swift; `.git` at temp_dir root → "main" |
| `testReadGitWorktreeFileDereferencesGitdir` | Temp dir's `.git` is a FILE with content `"gitdir: /tmp/main/.git/worktrees/T5\n"`, real `HEAD` lives at the gitdir → branch resolved |
| `testReadTildePrefixedPathExpandsToAbsolute` | Pass `~/.tmp/fixture/file.swift` → tilde expanded → fs walked correctly |
| `testReadEmptyHEADFileReturnsNil` | `.git/HEAD` empty file → nil |

Total **7 moat tests**.

**`Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsCurrentTaskIdentityIntegrationTests.swift`** (NEW):

| Test | Asserts |
|---|---|
| `testXcodeForegroundResolvesBranchViaGitHeadReader` | Seed `xcode_active_doc_changed` event with `doc_path` pointing to temp fixture with `.git/HEAD` "ref: refs/heads/feature/leaf-204-fix" → currentTaskIdentity returns branch="feature/leaf-204-fix", linearID="LEAF-204" |
| `testVSCodeForegroundResolvesBranchViaWorkspaceRoot` | Seed `vscode_workspace_opened` event with `workspace_root` ~-prefixed; foreground via attention event for Cursor bundle. Tilde expanded → branch resolved |
| `testSlackForegroundFallsBackToWindowTitleHeuristic` | Seed attention event for "com.tinyspeck.slackmacgap" with `window_title` containing "feature/leaf-100-foo". Resolver returns nil → extractBranchToken extracts "feature/leaf-100-foo", linearID="LEAF-100" |

Total **3 moat integration tests**.

### 5.3 Total test delta

| Surface | New tests |
|---|---|
| LeafCoreTests (public) | 6 (3 YouNowFocus + 2 deriver + 1 sentinel) |
| LeafCorePrivateTests (moat) | 16 (6 resolver + 7 git reader + 3 integration) |
| **Total** | **22 net new tests** |

T4 baseline = 2926 (2881 XCTest + 45 Swift-Testing). Post-T5 expectation: **~2948 total** (+22).

### 5.4 Sentinel-injection invariant

T5 reads `doc_path` from `xcode_active_doc_changed` events but does NOT emit any new events containing path bytes. The path is consumed in-memory by `WorkspacePathResolver` → `GitHeadReader` → branch name returned (path itself discarded).

Invariant: after `currentTaskIdentity()` runs with a sentinel-bearing doc_path:
- `presence_state.state_json` for any provider must NOT contain the sentinel substring (T5 does not write presence_state).
- `events.payload_json` for any row written DURING the test must NOT contain the sentinel — only the pre-seeded `xcode_active_doc_changed` row (which is the input, not T5 output) carries it.
- `TaskIdentity.workspacePath` is nil (D-8 invariant), so no materialized value containing the path bytes.

Sentinel: `LEAKED_SENTINEL_T5_DOCPATH`. Pattern parity with Track-9 T1 `LEAKED_SENTINEL_VSCODE_USERNAME` (injected at position that MUST NOT leak — username/path slots).

---

## 6. Files touched

| File | Change | Approx LOC |
|---|---|---|
| `Packages/LeafCore/Sources/LeafCore/Insights/YouNowState.swift` | MODIFY — +branch +linearID defaulted on YouNowFocus | +20 |
| `Packages/LeafCore/Sources/LeafCore/Insights/YouNowStateDeriver.swift` | MODIFY — pipe branch/linearID to .deepWorkFocus case | +5 |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/WorkspacePathResolver.swift` | NEW (moat) | ~110 |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/GitHeadReader.swift` | NEW (moat) | ~130 |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+CurrentTaskIdentity.swift` | REWRITE body — Stage 1+2+3 flow w/ dual LinearID source | rewrite |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+YouNowState.swift` | MODIFY — branch/linearID through to focus | +5 |
| `Leaf/Views/Window/Home/Blocks/YouNowBlock.swift` | MODIFY — 4 changes (label tweak / intensity hint / focusContent extension / Resume CTA) | +60 / -10 |
| `Leaf/Routing/RouteCoordinator.swift` | MODIFY — pushSettingsSystemObservers() | +10 |
| `Packages/LeafCore/Tests/LeafCoreTests/Insights/YouNowFocusEnrichmentTests.swift` | NEW | ~80 |
| `Packages/LeafCore/Tests/LeafCoreTests/Insights/YouNowStateDeriverFocusEnrichmentTests.swift` | NEW | ~80 |
| `Packages/LeafCore/Tests/LeafCoreTests/Privacy/RelayBodyLeakageTests.swift` | EXTEND — +1 sentinel test | +50 |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/WorkspacePathResolverTests.swift` | NEW (moat) | ~250 |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/GitHeadReaderTests.swift` | NEW (moat) | ~280 |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsCurrentTaskIdentityIntegrationTests.swift` | NEW (moat) | ~180 |

**Public-only LOC delta:** ~300. **Moat LOC delta:** ~950.

**Zero touches:**
- `Packages/LeafCore/Sources/LeafCore/DB/` (no migrations)
- `Packages/LeafCore/Sources/LeafCore/Privacy/ShareEventTypeKey.swift` (registry frozen)
- `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` (registry frozen)
- `LeafMCP/` (no new tools)
- `LeafAgent/` (no collector changes)

---

## 7. Sub-agent decomposition (Stage 5)

**Agents 1 + 2 dispatched параллельно single message** (truly independent files):
- **Agent 1** — `WorkspacePathResolver` (moat) + 6 moat tests.
- **Agent 2** — `GitHeadReader` (moat) + 7 moat tests.

**Agent 3** (sequential after 1+2):
- `currentTaskIdentity()` body rewrite preserving window_title fallback + 3 moat integration tests.

**Agent 4** (sequential after 3):
- `YouNowFocus +branch +linearID` defaulted fields + `YouNowStateDeriver` pipe extension + `ProdInsights+YouNowState` thread-through + `YouNowBlock.focusContent` UI extension + 5 public tests. Bundled — Agent 4 owns end-to-end focus enrichment surface.

**Agent 5** (sequential after 4 to avoid YouNowBlock merge conflict):
- `YouNowBlock` non-focus UI batch: label tweak (`"X min focused"`) + intensity UX hint conditional view + Resume CTA LinearID-aware label.
- `RouteCoordinator.pushSettingsSystemObservers()` convenience method.

**Agent 6** (sequential after 5; can be main session):
- `RelayBodyLeakageTests` sentinel test + verification gates (5/5 xcodebuild + SPM full + zero-diff invariants + check-tokens + privacy walkback narrow grep + spec status SHIPPED commit).

---

## 8. Out of scope (carry list)

| Carry | Target | Notes |
|---|---|---|
| Cached resolver with FSEvents invalidation (Q2 Option B) | Post-Track-9 if perf | Sub-ms fs walk doesn't justify cache complexity today. |
| `git_branch_changed` capture-path event_kind (Q2 Option C) | Not on roadmap | Substrate purity broken. Won't ship. |
| Multi-window foreground tracking for VSCode/JetBrains | Post-Track-9 | Requires AppleScript/AX per-IDE plumbing — substantial new scope. |
| `TaskIdentity.workspacePath` population | T6+ if UI needs | Conservative default. T5 keeps nil. |
| Dynamic `LinearIDPrefixCache` workspace whitelist | v1.1 | T5 reuses hardcoded `["LEAF"]` Phase 8.1 set. |
| YouNowBlock SwiftUI snapshot tests | Not on roadmap | No Track-8 precedent; manual smoke verifies UI bits. |
| T6 `SurfacePill` discriminator refactor | T6 | Separate phase. |
| YouNowBlock typography / spacing / а11y polish | T10 wrap | T5 ships functional changes only. |
| Master spec §T5 amendment (refinements A-E) | T10 wrap | T5 spec is authoritative implementation contract. |

---

## 9. Open questions

None — all 7 Stage 2 brainstorm questions resolved (D-1..D-19 в §2). User approved Full T5 scope + 5 self-review refinements + 2 AC additions (AC-16 worktree, AC-17 non-IDE fallback).

---

## 10. Master spec §T5 amendment plan (T10 wrap)

Когда T10 wrap, master spec §T5 line 180-188 amend:

- Add Refinement A: "Window-title fallback preserved when WorkspacePathResolver returns nil".
- Add Refinement B: "Multi-window foreground tracking known limitation (latest opened workspace returned)".
- Add Refinement C: "`TaskIdentity.workspacePath` stays nil — T5 does not populate".
- Add Refinement D: "Worktree support via `gitdir:` pointer dereferencing in GitHeadReader".
- Add Refinement E: "`ideWorkspacePathTrackingEnabled = false` graceful degrade to window_title fallback".
- Net deltas updated: zero new event_kinds / migrations / MCP tools / ShareEventTypeKey delta.
