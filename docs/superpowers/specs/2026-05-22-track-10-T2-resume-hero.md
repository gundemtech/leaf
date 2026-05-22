# Track-10 T2 — RESUME hero phase spec

**Status**: Stage 3 (per-phase spec) closed. Authored 2026-05-22 from approved Stage 4 plan `~/.claude/plans/track-10-t2-resume-parallel-frost.md` after Stages 1-2 brainstorm + CTO review pass (13 findings dispositioned). Stages 5-8 (implementation / review / verification / ship) landed in the same calendar day; this spec is the post-implementation source of truth.

**Branch**: `feature/track-10-operational-home` (off Track-10 T1 SHIPPED tip `2215f763`).

**Master spec contract**: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` — §4 T2 · §3.1 · §5.4 · §5.8 · §6 · §7.2.

**T1 precedent spec**: `docs/superpowers/specs/2026-05-22-track-10-T1-foundation.md`.

---

## 1. Goal

Promote the Track-9 T7 small bottom WHERE STOPPED card (159 LOC, Zone 4 in HomeView — invisible in practice per Track-9 wrap manual smoke) to a **hero card on top of Home** with three operational CTAs (Resume / Linear / Diff with main) and add **in-process git delta information** (commits ahead/behind merge base + uncommitted file count + parsed GitHub remote) read in-process from the workspace `.git` directory.

T2 is the first Track-10 phase touching capture-moat substrate:

1. First Process/subprocess pattern in LeafCorePrivate (Track-9 T5 `GitHeadReader` is pure file-I/O; T2 ships first `Process` invocations against `/usr/bin/git`).
2. Only Track-10 phase shipping a new sentinel-injection test (`testGitDeltaReader_StripsWorkspacePathAndFilenamesFromSnapshot`).
3. First read of `currentTaskIdentity()` from `InsightsReader.refresh()` (previously invoked only inside the moat by other Insights methods).
4. First new ephemeral `currentWorkspacePath()` method on `DerivedInsights` (Track-9 T5 D-8 keeps `workspacePath` OUT of `TaskIdentity` — T2 adds a separate accessor whose output never reaches `InsightsSnapshot`).

Net: 7 atomic implementation commits + 1 spec landing commit = 8 commits. Substrate additions:

- 1 new public protocol (`GitDeltaReader`) + factory machinery (`GitDeltaReaderFactory` write-once-read-many, mirrors `TeammatePresenceReaderFactory`).
- 2 new public value types (`GitDeltaSnapshot`, `GitRemoteRef`).
- 3 new defaulted-init fields on existing public types:
    - `InsightsSnapshot.gitDelta: GitDeltaSnapshot?`
    - `InsightsSnapshot.currentTaskIdentity: TaskIdentity?`
    - `TaskIdentity.linearWorkspaceSlug: String?`
    - `WhereStoppedSnapshot.anchorBundleID: String?`
- 1 new protocol method on `DerivedInsights` (`currentWorkspacePath() throws -> String?` with default `nil`).
- 1 new method on `RouteCoordinator` (`openExternalURL(_:)`).
- 1 new view file (`ResumeHeroBlock.swift`, 222 LOC) + 1 deleted view file (`WhereStoppedBlock.swift`, 159 LOC).
- 2 new sequential calls in `InsightsReader.refresh()` pipeline (`currentTaskIdentity()` + `currentWorkspacePath()` + `GitDeltaReaderFactory.make().read(...)` — 22 → 24 calls).

Zero changes to: event_kinds registry (198 frozen) · SQLCipher migrations (30 tables) · MCP tools (15 frozen) · `ShareEventTypeKey` entries.

---

## 2. Brainstorm decisions

| Q | Decision | Reason |
|---|---|---|
| Q1 `GitDeltaReader.read` async or sync? | **Async** | Aligns with InsightsReader.refresh() 22-call async pipeline; natural `Task.checkCancellation` + per-subprocess timeout; subprocess work in `Task.detached`. |
| Q2 mergeBase / ahead-behind derivation | **symbolic-ref + left-right rev-list + status + remote get-url** | 4-subprocess happy path: (1) `git symbolic-ref refs/remotes/origin/HEAD`, (2) `git rev-list --left-right --count HEAD...<ref>`, (3) `git status --porcelain --untracked-files=no`, (4) `git remote get-url origin`. Fallback chain: rev-parse origin/main → rev-parse origin/master → return partial snapshot (mergeBase nil). |
| Q3 Resume CTA target app | **`WhereStoppedSnapshot.anchorBundleID: String?` defaulted field** | Populated by reader (`ProdInsights+RecentWhereStopped`) from existing LEFT-JOIN `events.bundle_id`. CTA: open via `LocalAppsStore.isEnabled` + `NSWorkspace.urlForApplication`; hidden when nil. |
| Q4 Diff with main URL: remote parsing | **`GitRemoteRef` substruct on `GitDeltaSnapshot`** | `{ host, owner, repo }`. Reader runs +1 subprocess `git remote get-url origin`, parses ssh + https patterns. View composes `https://github.com/<owner>/<repo>/compare/<refBasename>...<branch>` when host == "github.com", hides CTA otherwise. |
| Q5 Stale data policy | **Fresh fetch every refresh** | ~4 subprocesses per refresh amortized in 22-call pipeline. Commit → banner immediate. Zero cache invalidation logic. YAGNI on TTL until metrics show waste. |
| Q6 All-zero state for WIP line | **Hide line entirely** | All-zero → no line. Partial states → smart-compose: drop zero clauses, join non-zero with " · ". Zero noise on clean branches. |
| Q7 Line format "+4" vs "4" | **No '+' prefix — "4 commits ahead of main"** | Matches master spec §3.1 verbatim. Natural English. §3.6 wording amended at T9 wrap. |
| Q8 Sentinel-injection scope | **V1 + V2 — workspace path + uncommitted filename** | Setup tmp workspace with sentinel-bearing path + sentinel-bearing uncommitted file. Assert field-by-field that snapshot fields don't contain sentinel + belt-and-suspenders `String(describing:)` Mirror dump guard. |
| Q9 External URL opening | **`RouteCoordinator.openExternalURL(_:)` helper** | Single generic method calling `NSWorkspace.shared.open(url)`. Centralized so view layer doesn't import AppKit. Ready for T5 SINCE timeline row-tap reuse. |
| Q10 Null gitDelta render policy | **Graceful per-element — hide only WIP line + Diff CTA** | WhereStopped fields render normally (header / LEAF-ID / branch / anchor file:line / last commit). Suppress WIP line only when gitDelta nil OR all-zero. Hide Diff CTA when gitDelta nil OR remote.host != "github.com". Resume + Linear CTAs gitDelta-independent. |
| Q11 Linear workspace slug source (Stage 5 first-look) | **Read from `presence_state.linear.state_json $.workspace_slug` via new `linearWorkspaceSlug` field on `TaskIdentity`** | Slug captured by `ProdLinearGraphQLProvider` (Track-9 T2) on first non-nil page of a polling tick; existing `ProdInsights+InboxItems.readLinearWorkspaceSlug()` pattern reused locally inside `ProdInsights+CurrentTaskIdentity`. |
| Q12 Workspace path on `TaskIdentity` (Stage 5 first-look) | **Keep OUT per T5 D-8 — add ephemeral `currentWorkspacePath()` protocol method** | Track-9 T5 D-8 documented absolute-path-bytes risk via TaskIdentity → InsightsSnapshot → MCP serialization. T2 keeps that discipline and adds a separate accessor whose output never reaches the snapshot. |

---

## 3. Spec sections

### 3.1 Public substrate (LeafCore additions)

```swift
// Packages/LeafCore/Sources/LeafCore/Git/GitDeltaSnapshot.swift  (NEW, 39 LOC)
public struct GitDeltaSnapshot: Equatable, Hashable, Sendable {
    public let commitsAhead: Int
    public let commitsBehind: Int
    public let uncommittedCount: Int
    public let mergeBase: String?          // e.g. "origin/main"
    public let remote: GitRemoteRef?
    public init(commitsAhead: Int, commitsBehind: Int, uncommittedCount: Int,
                mergeBase: String? = nil, remote: GitRemoteRef? = nil) { ... }
}

public struct GitRemoteRef: Equatable, Hashable, Sendable {
    public let host: String                // e.g. "github.com"
    public let owner: String               // e.g. "gundemtech"
    public let repo: String                // e.g. "leaf"
    public init(host: String, owner: String, repo: String) { ... }
}
```

```swift
// Packages/LeafCore/Sources/LeafCore/Git/GitDeltaReader.swift  (NEW, 35 LOC)
public protocol GitDeltaReader: Sendable {
    func read(forWorkspacePath path: String?) async -> GitDeltaSnapshot?
}

public struct StubGitDeltaReader: GitDeltaReader {
    public init() {}
    public func read(forWorkspacePath path: String?) async -> GitDeltaSnapshot? { nil }
}

public enum GitDeltaReaderFactory {
    nonisolated(unsafe) private static var provider: (@Sendable () -> any GitDeltaReader)?
    public static func register(_ provider: @escaping @Sendable () -> any GitDeltaReader) { ... }
    public static func make() -> any GitDeltaReader { provider?() ?? StubGitDeltaReader() }
    public static func resetForTests() { provider = nil }
}
```

### 3.2 Snapshot composition

`InsightsSnapshot` gains 2 defaulted fields (CTO finding #3 — bundled):
```swift
public let gitDelta: GitDeltaSnapshot?         // default nil in both inits
public let currentTaskIdentity: TaskIdentity?  // default nil in both inits
```

`WhereStoppedSnapshot` gains:
```swift
public let anchorBundleID: String?             // default nil in both inits
```

`TaskIdentity` gains:
```swift
public let linearWorkspaceSlug: String?        // default nil; isEmpty check extended
```

`DerivedInsights` protocol gains:
```swift
func currentWorkspacePath() throws -> String?
extension DerivedInsights {
    public func currentWorkspacePath() throws -> String? { nil }  // stub fallback
}
```

`InsightsReader.refresh()` gains 2 sequential calls inserted after `weeklyMetrics`:
```swift
try Task.checkCancellation()
let taskIdentity = try insights.currentTaskIdentity()
try Task.checkCancellation()
let workspacePath = try insights.currentWorkspacePath()
let gitDelta = await GitDeltaReaderFactory.make().read(forWorkspacePath: workspacePath)
try Task.checkCancellation()
```

Call count 22 → 24 monotonic. Composition: pass both `gitDelta` + `taskIdentity` into `InsightsSnapshot` ctor at call site; `whereStopped` Path B splice now also forwards `anchorBundleID`. `workspacePath` stays ephemeral — never persisted in snapshot.

### 3.3 Moat impl (LeafCorePrivate gitignored)

`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Git/ProdGitDeltaReader.swift` (~210 LOC):

**Subprocess strategy** (happy path 4 invocations):
1. `git -C <workspace> symbolic-ref --short refs/remotes/origin/HEAD` → returns ref (e.g. `origin/main`) или non-zero exit.
2. `git -C <workspace> rev-list --left-right --count HEAD...<ref>` → returns `"<ahead>\t<behind>"`.
3. `git -C <workspace> status --porcelain --untracked-files=no` → wc -l → uncommittedCount (CTO #4 — tracked-modified/added/deleted/renamed/copied only).
4. `git -C <workspace> remote get-url origin` → URL string → parse ssh + https patterns → `GitRemoteRef` или nil.

**Fallback chain on step 1 fail**: `rev-parse origin/main` → `rev-parse origin/master` → return partial snapshot (mergeBase nil). When `git status` itself fails AND no mergeBase AND no remote → collapse to nil (not a workspace we can describe).

**Subprocess discipline** (ADR-010):
- Hardcoded `/usr/bin/git` (CTO #6 risk-accept — always present on macOS via Xcode CLT + system git; PATH-resolve enhancement deferred).
- Per-subprocess 5-second timeout via off-thread `Task.detached` watchdog that calls `process.terminate()` if `process.isRunning` after sleep.
- Cancellation propagated via `withTaskCancellationHandler` — `onCancel` closure calls `process.terminate()`, causing the blocking `waitUntilExit()` to return and the sync block to collapse to nil.
- stderr piped to a discard `Pipe()` — never read, never surfaced.
- `try?` graceful — any throw / non-zero exit / parse failure → nil for that step.

**Bootstrap registration** in `Leaf/LeafApp.swift` adjacent to `DerivedInsightsFactory.register` line 88, inside existing `#if LEAF_PROD` gate:
```swift
GitDeltaReaderFactory.register { LeafCorePrivate.ProdGitDeltaReader() }
```

**Sentinel-injection test** `Packages/LeafCore/Tests/LeafCorePrivateTests/Git/ProdGitDeltaReaderTests.swift` (~210 LOC, 14 tests):
- 6 nil/empty/no-repo path tests.
- 3 functional tests (clean repo / dirty tracked / untracked-ignored per CTO #4).
- 4 `parseRemoteURL` / `parseLeftRightCount` static helper tests.
- 1 cancellation test (`Task.cancel()` resolves the awaiter without hanging).
- 1 **`test_gitDeltaReader_StripsWorkspacePathAndFilenamesFromSnapshot`** (CTO #7 field-by-field):
    - Tmp workspace path embeds `LEAKED_SENTINEL_T2_GIT_DELTA`.
    - Uncommitted tracked filename embeds same sentinel.
    - Assert `snapshot.uncommittedCount == 1` (substrate semantics work).
    - Assert sentinel NOT in `snapshot.mergeBase` / `snapshot.remote?.host` / `.owner` / `.repo`.
    - Belt-and-suspenders `String(describing: snapshot).contains(sentinel) == false` guard.

### 3.4 Moat reader patches (LeafCorePrivate gitignored)

`ProdInsights+CurrentTaskIdentity.swift` extended:
- Reads `workspace_slug` from `presence_state.linear.state_json $.workspace_slug` (mirror of `ProdInsights+InboxItems.readLinearWorkspaceSlug()` — kept local to avoid cross-extension visibility coupling).
- Populates new `TaskIdentity.linearWorkspaceSlug`. `workspacePath` STILL nil per T5 D-8.
- New public method `currentWorkspacePath() throws -> String?` returns ephemeral path via existing `WorkspacePathResolver.resolve(bundleID:db:)`.

`ProdInsights+RecentWhereStopped.swift` extended:
- SELECT extended with `e.bundle_id AS anchor_bundle_id` (existing LEFT JOIN already in scope per CTO finding #2).
- Row decode passes `anchorBundleID: String?` (empty-string defended) into snapshot ctor.

### 3.5 Resume CTA target app (Q3 substrate flow)

```
event row → ProdInsights+RecentWhereStopped (SELECT e.bundle_id) →
WhereStoppedSnapshot.anchorBundleID → ResumeHeroBlock.resumeBundleID gate →
NSWorkspace.urlForApplication → [Resume] CTA opens
```

Gate parity with `YouNowBlock.away` pattern:
```swift
private var resumeBundleID: String? {
    guard let bundleID = snapshot?.anchorBundleID,
          localAppsStore.isEnabled(bundleID),
          NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    else { return nil }
    return bundleID
}
```

LocalAppsStore reactivity: still `ObservableObject` per Track-9 §9.1 C-5 carry (deferred to own phase).

### 3.6 View layout

`ResumeHeroBlock.swift` (222 LOC) renders top-to-bottom:

```
RESUME · 16h ago                                         [section header]
LEAF-204 · feature/track-10-operational-home             [task line — TaskIdentity]
StreaksCard.swift:84                                     [anchor file:line — WhereStoppedSnapshot]
Last commit: "feat(track-9-T10): SHIPPED ..."            [commit subject, 60-char cap]
WIP: 3 uncommitted · 4 commits ahead of main             [gitDelta composition]

[Resume]  [Linear LEAF-204]  [Diff with main]            [3 CTAs, each self-gating]
```

`composeWipLine()` helper drops zero clauses, joins non-zero with " · ". Returns `nil` when all clauses zero / no mergeBase → caller hides line entirely.

`refBasename(_:)` helper splits on `/` and returns the last segment ("origin/main" → "main"). Single-segment refs pass through.

3 CTAs (HStack):
- **Resume** — anchor bundleID + LocalAppsStore + urlForApplication gate.
- **Linear LEAF-NN** — `taskIdentity.linearID` + `taskIdentity.linearWorkspaceSlug` (hidden pre-OAuth or when slug absent).
- **Diff with main** — `gitDelta.remote.host == "github.com"` + `branch` + `mergeBase` (URL-encoded ref names for safety).

Empty state (`snapshot == nil` and `taskIdentity?.isEmpty == true`): `LeafEmptyState` "No recent work captured" + "Open an IDE or pin a Linear issue to populate this card."

### 3.7 HomeView Zone 1 rewire

```
Before T2 (post-Track-9 T7):              After T2:
  Zone 1: TodayBlock                        Zone 1: ResumeHeroBlock           ← NEW HERO
  Zone 2: HStack [YouNow ‖ WithYou]         Zone 2: TodayBlock                ← was Zone 1
  Zone 3: InboxBlock                        Zone 3: HStack [YouNow ‖ WithYou] ← was Zone 2
  Zone 4: WhereStoppedBlock                 Zone 4: InboxBlock                ← was Zone 3
                                                                              ← Zone 4 retired
```

HomeView LOC: 270 → 276 (well within Track-10 cap 310 per master spec §7.2 gate 6).

### 3.8 Verification gates (per master spec §7.2)

T2 ships with all gates green:

1. **5/5 xcodebuild Debug schemes** — Leaf / LeafAgent / LeafMCP / LeafCore / LeafCorePrivate.
2. **SPM tests** — LeafCore baseline 2013 + 7 new (4 GitDeltaSnapshot + 3 InsightsSnapshot field defaults); LeafCorePrivate baseline + 17 new (14 ProdGitDeltaReader + 3 anchorBundleID).
3. **Privacy walkback grep** narrow scope (T2 file set), 0 hits forbidden fields.
4. **Sentinel-injection test green** — `test_gitDeltaReader_StripsWorkspacePathAndFilenamesFromSnapshot`.
5. **HomeView.swift LOC** = 276 ≤ 310.
6. **InsightsReader.refresh() call count** monotonic — 22 → 24.
7. **No new SQLCipher migrations** — empty diff.
8. **No new ShareEventTypeKey entries** — registry frozen at 198.

Manual smoke (Дима driver after Stage 6 review):
- Open Leaf in `~/Desktop/Leaf/leaf` (workspace with uncommitted changes + ahead-of-main commits).
- RESUME hero renders on top: header / task line / file:line anchor / last commit / WIP line / 3 CTAs.
- WIP line shows e.g. "WIP: 3 uncommitted · 5 commits ahead of main".
- Click **Resume** → Xcode (or current anchor app) opens.
- Click **Linear LEAF-NNN** → browser opens Linear issue.
- Click **Diff with main** → browser opens `github.com/gundemtech/leaf/compare/main...feature/track-10-operational-home`.
- Switch to a clean workspace (no ahead, no uncommitted) → WIP line disappears entirely.
- Open Leaf on a workspace WITHOUT git remote → Diff CTA hidden; Resume + Linear still work.
- Open Leaf on a non-git directory → gitDelta nil → entire WIP line hidden.

### 3.9 Out of scope

- TTL caching of `GitDeltaSnapshot` (Q5 carry — add if metrics show waste post-Track-10).
- `git remote get-url` parsing for non-GitHub hosts (Bitbucket / GitLab) — Q4 carry.
- Subprocess via Swift Process API timeout via `DispatchSource` (current impl uses Task-based watchdog).
- View-layer unit tests for `ResumeHeroBlock` — Leaf precedent skips UI tests (Leaf.xcodeproj has no test target); Track-9 §9.3 C-43 carry covers framework adoption.
- ProdGitDeltaReader benchmark / metrics — defer to v1.1.
- LocalAppsStore reactivity (`@Observable` migration) — Track-9 §9.1 C-5 carry, own phase.

---

## 4. Master spec amendments (T9 wrap emit list)

T2 emits these into Track-10 carries (apply at T9 wrap):

1. **§5.4** add row: `WhereStoppedSnapshot.anchorBundleID: String?` — populated by reader; powers RESUME Resume CTA target app.
2. **§5.4** add row: `GitRemoteRef` value type — `{ host, owner, repo }`; bundled into `GitDeltaSnapshot.remote`.
3. **§5.4** add row: `TaskIdentity.linearWorkspaceSlug: String?` — read from `presence_state.linear` by moat reader; powers Linear CTA URL composition.
4. **§5.4** add row: `DerivedInsights.currentWorkspacePath() throws -> String?` — ephemeral protocol method; default `nil`; production impl reuses `WorkspacePathResolver`. Kept OUT of `TaskIdentity` per T5 D-8.
5. **§6** wording amendment: "T2 sentinel-injection test lives in `ProdGitDeltaReaderTests.swift` (moat-side), not `RelayBodyLeakageTests.swift` — surface is subprocess→snapshot, not event→presence_state". Test name `test_gitDeltaReader_StripsWorkspacePathAndFilenamesFromSnapshot`.
6. **§7.2** baseline correction: "Track-9 ended at 23 calls" → actual 22; T2 ends at 24 (`currentTaskIdentity` + `currentWorkspacePath`+`GitDeltaReaderFactory.make().read`).
7. **§5.4** wording amendment: "subprocess mirroring `GitHeadReader` precedent" → "subprocess pattern new for moat; `GitHeadReader` is file-I/O precedent for `try?` graceful-nil discipline only".
8. **§3.6 wording** for YOU'RE ON (T7 phase): "+5 ahead of main" → "5 commits ahead of main" to align with §3.1 verbatim and Q7 decision.
9. **§4 T2** subprocess count clarification — happy path 4 invocations; fallback chain up to 6.

---

## 5. CTO review findings disposition (Stage 4.5)

13 findings audited against plan. Inline fixes applied; risk-accepts dispositioned with rationale. Each disposition reflected in commit bodies.

| # | Sev | Finding | Disposition |
|---|---|---|---|
| 1 | CRITICAL | Plan used `@EnvironmentObject var router: RouteCoordinator` — wrong API; `RouteCoordinator` is `@Observable`. | FIXED INLINE — `@Environment(RouteCoordinator.self) private var coordinator`. |
| 2 | CRITICAL | Plan patched `ProdWhereStoppedDeriver.swift` (writer) for anchorBundleID. | FIXED INLINE — patched `ProdInsights+RecentWhereStopped.swift` (reader) where existing LEFT JOIN on `events` already in scope. |
| 3 | CRITICAL | `currentTaskIdentity()` confirmed not previously called by `InsightsReader.refresh()`. | FIXED INLINE — bundled `currentTaskIdentity` as defaulted snapshot field in C2; composed via reader in C6. Call count 22 → 24. |
| 4 | HIGH | `git status --porcelain` includes untracked files by default. | FIXED INLINE — `--untracked-files=no` flag. Tested via `test_readIgnoresUntrackedFiles_PerCleanWipSignal`. |
| 5 | HIGH | Plan subprocess discipline lacked cancellation. | FIXED INLINE — `withTaskCancellationHandler { } onCancel: { process.terminate() }` + detached timeout watchdog. Tested via `test_readCancellation_ResolvesAfterCancel`. |
| 6 | HIGH | `/usr/bin/git` hardcoding — Homebrew users on Apple Silicon. | RISK-ACCEPT — system git always present on macOS via Xcode CLT. Future polish if Homebrew-only users surface. Documented in commit body. |
| 7 | HIGH | Sentinel test using `String(describing:)` Mirror reflection — too weak. | FIXED INLINE — field-by-field assertions on mergeBase + remote.host/owner/repo + uncommittedCount + belt-and-suspenders Mirror dump guard. |
| 8 | MEDIUM | "~60 fixture callsites" overestimate for `InsightsSnapshot`. | FIXED INLINE — adjusted to "~31 callsites preserved via default-init pattern" (1 prod + 30 test). |
| 9 | MEDIUM | Subprocess timeout impl handwaved. | FIXED INLINE — concrete off-thread `Task.detached` watchdog calling `process.terminate()` if alive after sleep. |
| 10 | MEDIUM | Linear CTA workspace slug fallback. | FIXED INLINE — `linearWorkspaceSlug` field on `TaskIdentity` populated from `presence_state.linear`; CTA hidden when slug nil. |
| 11 | MEDIUM | Subprocess failure observability silent. | DEFER — Settings → Diagnostics extension follow-up. Not blocking. |
| 12 | LOW | `refBasename` edge case for multi-segment default branches. | RISK-ACCEPT — vast majority of default branches single-segment. |
| 13 | LOW | Test directory creation. | FIXED INLINE — Write tool auto-creates parent dirs. |

---

## 6. References

- Master spec: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md`.
- T1 precedent spec: `docs/superpowers/specs/2026-05-22-track-10-T1-foundation.md`.
- Track-9 T7 spec (precedent for WhereStoppedSnapshot composition): `docs/superpowers/specs/2026-05-{20,21}-track-9-T7-*.md`.
- Track-9 T5 `GitHeadReader` (file-I/O precedent for `try?` graceful-nil discipline): `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/GitHeadReader.swift` (moat — gitignored).
- `.claude/shared/architecture.md` — substrate baseline.
- `.claude/shared/conventions.md` — 8-stage workflow.
- ADR-010 walkback discipline — sentinel-injection lineage.
