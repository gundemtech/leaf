# Track-10 T7 — YOU'RE ON anchor block phase spec

**Linear**: GUN-50
**Status**: SHIPPED 2026-05-23. Authored from approved Stages 1-2 brainstorm
(Q1..Q9 closed) + Stage 4 plan `~/.claude/plans/enchanted-hopping-steele.md`
+ Stage 4.5 CTO double-pass (8 HIGH inline-fixed / 5 MEDIUM / 7 LOW;
0 outstanding CRITICAL). Stages 5-8 (implementation / review / verification
/ ship) landed 2026-05-23. Commit trail on
`feature/GUN-50-track-10-T7-youre-on-anchor`:
- C1 `cdc7a31b` — CurrentTaskSession value type + protocol method + tests
- C2 (gitignored moat) — ProdInsights+CurrentTaskSession + sentinel test
- C3 `6393d4e6` — InsightsSnapshot.currentSession + InsightsReader composition
- C4 `f9ebf6a9` — HomeContent.swift extraction (zero behavior)
- C5 `19ec47c7` — YoureOnBlock + YoureOnRowComposer + Zone-4 ViewThatFits rewire
- fix `b9039eb3` — Stage 6 review fix-bundle (HomeView doc comment refresh)
- C6 (this commit) — SHIPPED docs landing
Stage 6 dual review: code APPROVE-WITH-NITS (0 BLOCKERS, 1 IMPORTANT
fix-bundled inline, 7 NITs → T9 polish carries) + a11y APPROVE-WITH-NITS
(0 BLOCKERS, 0 IMPORTANTS, 5 NITs → T10). Stage 7: 9/9 §7.2 gates green.

**Branch**: `feature/GUN-50-track-10-T7-youre-on-anchor` (off
`feature/track-10-operational-home` tip `a4f8e7f4` = T6 SHIPPED after
FF-merge of `feature/GUN-48-track-10-T6-team-n-broader-pulse`).

**Master spec contract**: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` —
§4 T7 · §3.6 · §5.4 · §5.5 · §6 · §7.2.

**Precedent specs**:
- T2 RESUME hero (GitDeltaSnapshot consumer · TaskIdentity reuse ·
  ephemeral protocol method pattern · 7+1 commit decomposition):
  `docs/superpowers/specs/2026-05-22-track-10-T2-resume-hero.md`.
- T5 SINCE YOU WERE LAST ACTIVE (defaulted-init 12th iteration · pure
  bundled value type + protocol method substrate pattern · Stage 6 dual
  review):
  `docs/superpowers/specs/2026-05-22-track-10-T5-since-last-active.md`.
- T6 TEAM·N broader pulse (ViewThatFits 2-col Zone precedent ·
  LeafCore pure-helper extraction for testability ·
  defaulted-init 13th iteration):
  `docs/superpowers/specs/2026-05-23-track-10-T6-team-n-broader-pulse.md`.

---

## 1. Goal

New Zone-4 Home block **YOU'RE ON** — task session lens distinct from
YOU·NOW (instant-level state badge) and RESUME (yesterday-level
context). Surfaces what the user is on **right now today**: LEAF-ID,
branch, commits ahead of merge base, session start clock, focused
minutes so far on this task, and recent open files in the current
workspace.

T7 is **substrate-additive** but still classified pure-Home-track:

- 1 new public value type (`CurrentTaskSession`) bundling 4 derived fields.
- 1 new public protocol method (`DerivedInsights.currentTaskSession()`)
  with default `nil` extension.
- 1 new moat impl extension (`ProdInsights+CurrentTaskSession.swift`)
  composing the bundle via per-IDE dispatch + per-task focused-min
  walk + basename-only open-files projection.
- 1 new defaulted-init field on `InsightsSnapshot.currentSession`.
- 1 new public LeafCore helpers module (`YoureOnRowComposer.swift`)
  for testable pure rendering compositions.
- 1 new SwiftUI block view (`YoureOnBlock.swift`).
- 1 view tier refactor: extract `HomeContent` from inside
  `HomeView.swift` into its own file (defensive LOC pre-payment for
  master spec §7.2 gate 6 ≤ 310 invariant).
- HomeView Zone-4 rewires from T5's full-width `SinceLastActiveBlock`
  callsite to `ViewThatFits` 2-col `SINCE ‖ YOU'RE ON` per master
  spec §2 scope lock #5.

Substrate-purity constants held:

- 0 new event_kinds (registry frozen at **198**).
- 0 new SQLCipher migrations (30 tables preserved).
- 0 new MCP tools (15 frozen).
- 0 new `ShareEventTypeKey` entries.
- T7 **EXEMPT** from §6 sentinel-injection (master spec §6 verbatim)
  plus 1 lightweight moat unit test for basename-only invariant —
  does NOT escalate to `RelayBodyLeakageTests` walkback.

Net diff target: ~7 new files / ~3 modified / ~700 +LOC across 5
atomic implementation commits + 1 SHIPPED docs commit.

---

## 2. Brainstorm decisions

| Q | Decision | Rationale |
|---|---|---|
| Q1 Zone-4 layout | **A — ViewThatFits 2-col `SINCE ‖ YOU'RE ON`** | Master spec §2 scope lock #5 parity ("5 zones dense grid · SINCE ‖ YOU'RE ON"). T6 ViewThatFits Zone-3 precedent reuse. T5 block body unchanged; T5 callsite migrates from HomeContent VStack child to ViewThatFits 2nd child. |
| Q2 HomeContent file extraction | **A — Extract in T7 as separate atomic commit** | LOC defense. T7 Zone-4 ViewThatFits 2-col rewire adds net ~25-30 LOC inline (HStack + VStack branches each duplicate SINCE+YOU'RE ON children per T6 precedent) → HomeView would overflow 310-cap → ~335 LOC. Extracting HomeContent to own file: HomeView 309 → ~175 LOC; HomeContent.swift ~115 LOC. Both well under cap. Master spec §7.2 gate 6 explicitly licenses HomeContent extraction. |
| Q3 openFiles cap | **A — 3 default** | Master spec §3.6 mockup shows 3 ("StreaksCard.swift · AnalyticsView.swift · WeeklyMetrics.swift"). Narrow Zone-4 2-col half-width (~280-320pt) fits 3 basenames; 5 would truncate. |
| Q4 openFiles filter scope | **A — Since sessionStartMs (fallback today 00:00)** | Matches task session window framing ("Open files: ..." reads as "in current task"). Correct on workspace task-switch. Fallback today-midnight for sessionStartMs=0 case (no IDE attention today). |
| Q5 sessionStartMs derivation | **A — Per-IDE dispatch** | Correct on workspace task-switch. Xcode `xcode_active_doc_changed.doc_path` → path-walk parents to `.git` (reuse WorkspacePathResolver primitive); VSCode-family `vscode_active_doc_changed.workspace_root` direct SQL filter via `json_extract(...)`; JetBrains `jetbrains_recent_project_observed.workspace_root` direct SQL filter. Earliest matching event today → sessionStartMs. |
| Q6 focusedMinSoFar semantic | **A — Per-task subset** | Master spec mockup "1h 32m focused so far" reads as per-task. Moat walks attention events (or focusSessions filtered by primary bundle == IDE foreground) since sessionStartMs, sums durations, divides by 60_000. Honest on multi-task day; today-total would lump prior-task time into "this task" reading. |
| Q7 Empty state copy | **A — Verbatim master spec, no CTA, block always visible** | "No active task identified — Leaf reads `LEAF-XXX` from branch names of foreground IDE workspaces." T5/T6 precedent. Block remains in Zone-4 ViewThatFits child position (don't break layout). |
| Q8 Sentinel scope | **A — EXEMPT + 1 moat unit test** | Master spec §6 verbatim EXEMPT (existing Track-9 T1 storage-side sentinel walks cover `vscode_active_doc_changed.workspace_root` allowlist). Add 1 moat unit test `test_currentTaskSession_OpenFilesAreBasenamesOnly_NoSentinelLeak` asserting `NSString.lastPathComponent` strips path content from `doc_path` w/ embedded sentinel. Does not escalate §6 classification. |
| Q9 API + commits | **A — Bundled `currentTaskSession()` + 6 atomic commits** | Single protocol method + single moat extension assembling the bundle (taskIdentity + sessionStartMs + focusedMinSoFar + openFiles). Replaces master spec §5.4 `openFilesInCurrentWorkspace(limit:)` row (amendment §8.1). 6 atomic commits per T2/T5/T6 cadence: C1 types · C2 moat impl · C3 snapshot+reader · C4 HomeContent extract · C5 YoureOnBlock+Zone-4 rewire · C6 spec landing + SHIPPED. |

---

## 3. Surface contract

### 3.1 Public substrate (LeafCore additions)

#### `CurrentTaskSession` (`LeafCore/Insights/CurrentTaskSession.swift`)

```swift
public struct CurrentTaskSession: Equatable, Hashable, Sendable, Codable {
    public let taskIdentity: TaskIdentity     // T2 substrate reuse
    public let sessionStartMs: Int64           // ms epoch; 0 = no IDE attention today
    public let focusedMinSoFar: Int            // per-task subset since sessionStartMs
    public let openFiles: [String]             // basenames-only, cap 3, recency-desc

    public init(
        taskIdentity: TaskIdentity,
        sessionStartMs: Int64,
        focusedMinSoFar: Int,
        openFiles: [String]
    ) { ... }
}
```

Equatable + Hashable used by SwiftUI diff. Codable used by snapshot
round-trip tests (defaulted-init pattern).

#### `DerivedInsights.currentTaskSession()` protocol method

```swift
extension DerivedInsights {
    public func currentTaskSession() throws -> CurrentTaskSession? { nil }
}
```

Default extension returns `nil` (stub for non-Prod test fixtures).
Production impl in LeafCorePrivate moat.

#### `InsightsSnapshot.currentSession` defaulted field

49th defaulted-init field (13th iteration of defaulted-init blast-radius
invariant T2 → T5 → T6 → T7).

```swift
// InsightsSnapshot.swift — append next to T6's memberCount field
public let currentSession: CurrentTaskSession?   // default nil

// Both public initializers gain `currentSession: CurrentTaskSession? = nil`
// parameter at tail position.
```

Fixture callsites preserved via default argument; existing tests
unchanged.

#### `YoureOnRowComposer` (`LeafCore/Home/YoureOnRowComposer.swift`)

Pure-function helpers extracted to LeafCore for testability (T6
`TeamNRowComposer` precedent). File-local SwiftUI body in
`YoureOnBlock.swift` calls these statically:

```swift
public enum YoureOnRowComposer {
    /// Composes "LEAF-204 · feature/track-9-substrate · +5 ahead of main".
    /// Returns nil when all three components missing → empty state route.
    public static func composeTaskLine(
        _ taskIdentity: TaskIdentity,
        gitDelta: GitDeltaSnapshot?
    ) -> String? { ... }

    /// Composes "Started 09:18 · 1h 32m focused so far".
    /// Returns nil when sessionStartMs == 0 (no IDE attention today).
    public static func composeSessionLine(
        sessionStartMs: Int64,
        focusedMin: Int,
        now: Date,
        calendar: Calendar
    ) -> String? { ... }

    /// Composes "Open files: A.swift · B.swift · C.swift".
    /// Returns nil when files empty.
    public static func composeFilesLine(_ files: [String]) -> String? { ... }

    /// "09:18" formatter — cached DateFormatter per Track-9 §9.3 C-37
    /// perf discipline (HomeRelativeTimeFormatter precedent).
    public static func formatSessionStart(
        _ ms: Int64,
        calendar: Calendar
    ) -> String { ... }

    /// "1h 32m" / "47m" / "" (when 0).
    public static func formatFocusedMin(_ min: Int) -> String { ... }

    /// A11y label composition (graceful nil-skip per component).
    public static func a11yLabel(
        _ taskIdentity: TaskIdentity,
        gitDelta: GitDeltaSnapshot?,
        sessionStartMs: Int64,
        focusedMin: Int,
        openFiles: [String],
        now: Date,
        calendar: Calendar
    ) -> String { ... }
}
```

`refBasename(_:)` reused from T2 ResumeHeroBlock (file-local helper)
for "+N ahead of main" suffix. T7 does NOT re-extract — T2's
file-local copy stays as-is; T7's composer has its own
`refBasename` static (acceptable duplication for now; rule-of-three
extraction carry to T9 polish if a third caller appears).

### 3.2 Moat impl (LeafCorePrivate gitignored)

`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+CurrentTaskSession.swift`
(~150-180 LOC).

**High-level derivation flow:**

```
1. taskIdentity = try currentTaskIdentity()       (T2 substrate)
   if taskIdentity == nil || taskIdentity.isEmpty → return nil

2. workspacePath = try currentWorkspacePath()      (T2 substrate)
   if workspacePath == nil → return nil

3. foregroundBundleID = lastActivity(bundleID: nil)?.bundleID
   (mirrors ProdInsights+CurrentTaskIdentity Stage 1)
   if foregroundBundleID == nil → return nil

4. sessionStartMs = derivePerIDEDispatchEarliestEventToday(
       foregroundBundle: foregroundBundleID,
       workspacePath: workspacePath
   )
   if no match → sessionStartMs = today00:00LocalTZ  (Q4 fallback)

5. focusedMinSoFar = walkAttentionDwellSince(
       bundleID: foregroundBundleID,
       since: sessionStartMs,
       now: now
   ) / 60_000

6. openFiles = collectRecentBasenames(
       workspacePath: workspacePath,
       since: sessionStartMs,
       cap: 3
   )

7. return CurrentTaskSession(taskIdentity, sessionStartMs,
                             focusedMinSoFar, openFiles)
```

**Per-IDE dispatch (step 4)** — single SQL query over events table
with `signal_type='attention' AND ts >= todayStartMs AND ts < endMs`,
post-filter in Swift per shape:

- `xcode_active_doc_changed`: extract `doc_path` payload field, walk
  parents via `WorkspacePathResolver`-style `.git`-discovery, compare
  normalized canonical path to `workspacePath`.
- `vscode_active_doc_changed` (and VSCode-family bundle IDs —
  Cursor, Insiders, VSCodium): extract `workspace_root` payload,
  normalize tilde-prefix (`~/...` → home-expand), compare.
- `jetbrains_recent_project_observed` (and 12 JetBrains family
  bundle IDs): same `workspace_root` shape as VSCode.

Take first matching event by `ts ASC` → sessionStartMs. Edge: no
match (rare — user worked entirely outside IDE today but task
identity still resolved via Track-9 substrate path-walks) →
sessionStartMs = today 00:00 local TZ fallback (Q4).

**Per-task focused-min walk (step 5)** — sum `attention_app_changed`
event durations where `bundle_id == foregroundBundleID` AND
`ts >= sessionStartMs AND ts < now`. Use LAG-based dwell SQL
(precedent: `ProdInsights+TodayMetrics.queryAttentionTransitionsCount`
LAG-window pattern) to compute event-to-event dwell deltas. Sum
deltas, divide by 60_000 for minutes. Document as "focused min
during current task session" — does NOT match exact `focusSessions`
session-boundary semantics; lighter computation matching
"task-anchor focused time" framing.

**Method choice — recommended order:**
1. **First-pick**: filter existing `focusSessions(period:)` output by
   `primary_bundle == foregroundBundleID` if focusSessions return
   shape exposes a per-session primary-bundle field. Reuses the
   canonical session-boundary derivation that powers
   `todayMetrics.focusedMin`; consistent semantics.
2. **Fallback**: LAG-window attention dwell SQL (`ProdInsights+TodayMetrics.queryAttentionTransitionsCount`
   precedent) summing `attention_app_changed` dwell deltas filtered
   by `bundle_id == foregroundBundleID AND ts >= sessionStartMs`.
   Lighter computation; semantic close-enough to session-boundary
   for "task-anchor focused time" framing.

Plan picks one canonical approach during impl (carry C-T7-5 for
post-ship reconciliation if approach divergence emerges across
tests vs production). Test coverage gates correctness regardless of
chosen path.

**openFiles collection (step 6)** — query events today (or
since sessionStartMs) with:

- `xcode_active_doc_changed` events filtered by Xcode bundle ID
  matching `currentTaskIdentity` foreground (per-IDE dispatch);
  extract `doc_path` → `NSString.lastPathComponent` for basename.
- `vscode_active_doc_changed` events filtered by
  `json_extract(payload_json, '$.workspace_root') = ?` match;
  prefer `file_basename` payload field (Track-9 T1 substrate
  confirmed via VSCodeFamilyTitleParser), fallback to
  `NSString.lastPathComponent(doc_path)` if `file_basename` absent.
- JetBrains events: workspace-level only, NO file-level surface
  available; skip entirely from openFiles collection.

Dedup by basename, sort by most-recent `ts` desc, cap 3. Result is
`[String]` basenames-only — every element MUST satisfy
`!contains("/")` (regression test in moat).

**Privacy discipline**: NEVER extract raw `doc_path` into bundle
field. `lastPathComponent` extraction performed BEFORE return — only
basenames cross the moat boundary. AAA `RelayBodyLeakageTests`
discipline already covers storage side per Track-9 T1 walkback
lineage; T7 moat unit test locks transformation correctness.

### 3.3 `InsightsReader.refresh()` composition (ordinal-28)

After T6's `memberCount` line (current T6 SHIPPED ordinal-27), one
new sequential call:

```swift
try Task.checkCancellation()
// Track-10 T7 — task session anchor (LEAF-ID + branch + commits ahead +
// session start + open files). Bundle stays nil for empty fixtures and
// Terminal-only work where currentTaskIdentity() can't resolve.
let currentSession = try insights.currentTaskSession()
try Task.checkCancellation()
```

`InsightsSnapshot` ctor gains `currentSession: currentSession,` at
tail position. SQL call count 27 → 28 (+1 monotonic, master spec
§7.2 gate 7 within range).

### 3.4 View tier

#### `HomeContent.swift` extraction (C4)

Move `private struct HomeContent: View { ... }` from current
`Leaf/Views/Window/Home/HomeView.swift` lines 209-309 into its
own file `Leaf/Views/Window/Home/HomeContent.swift`. Drop
`private` modifier (cross-file → `struct HomeContent: View`
becomes package-internal default visibility). Zero behavior change
in C4 — pure refactor commit.

LOC impact:
- HomeView.swift: 309 → ~175 (HomeView struct + reauth banners +
  state-machine helpers + LoadingScaffold remain).
- HomeContent.swift NEW: ~100 (cut-and-paste of lines 209-309 with
  privacy adjustment).

C5 then adds Zone-4 rewire on top of HomeContent.swift: net delta
~15-20 LOC → HomeContent.swift final ~115-120 LOC.

#### `YoureOnBlock.swift` (`Leaf/Views/Window/Home/Blocks/YoureOnBlock.swift`)

~150-180 LOC budget.

```swift
struct YoureOnBlock: View {
    let session: CurrentTaskSession?
    let gitDelta: GitDeltaSnapshot?
    @Environment(\.calendar) private var calendar  // ← timezone safety

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("YOU'RE ON")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("You're on, task anchor")

            LeafCard(padding: .regular) {
                if let session = session {
                    populated(session)
                } else {
                    emptyState
                }
            }
        }
    }

    @ViewBuilder
    private func populated(_ session: CurrentTaskSession) -> some View {
        let taskLine = YoureOnRowComposer.composeTaskLine(
            session.taskIdentity, gitDelta: gitDelta)
        let sessionLine = YoureOnRowComposer.composeSessionLine(
            sessionStartMs: session.sessionStartMs,
            focusedMin: session.focusedMinSoFar,
            now: Date(), calendar: calendar)
        let filesLine = YoureOnRowComposer.composeFilesLine(session.openFiles)

        // If all three lines collapse to nil → route to empty state.
        if taskLine == nil && sessionLine == nil && filesLine == nil {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                if let taskLine { line(taskLine, tone: .primary) }
                if let sessionLine { line(sessionLine, tone: .secondary) }
                if let filesLine { line(filesLine, tone: .secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(YoureOnRowComposer.a11yLabel(
                session.taskIdentity, gitDelta: gitDelta,
                sessionStartMs: session.sessionStartMs,
                focusedMin: session.focusedMinSoFar,
                openFiles: session.openFiles,
                now: Date(), calendar: calendar))
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "No active task identified — Leaf reads `LEAF-XXX` from branch names of foreground IDE workspaces.",
            description: nil,
            ctaTitle: nil,
            onCTA: nil
        )
    }

    @ViewBuilder
    private func line(_ text: String, tone: LeafTextTone) -> some View {
        Text(text)
            .font(LeafType.body.small)
            .foregroundStyle(tone == .primary
                ? LeafColor.text.primary
                : LeafColor.text.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
```

Block consumes `snapshot.currentSession` AND `snapshot.gitDelta`
(latter for "+N ahead of main" composition in task line; T2
substrate reuse).

Empty-state routing has **two entrances**:
1. Outer `session == nil` (e.g., currentTaskIdentity returns nil for
   Terminal-only work).
2. Inner all-three-lines-nil (e.g., session non-nil but taskLine +
   sessionLine + filesLine all skip — degenerate fixture, not seen
   in production). Single `emptyState` codepath collapses both.

#### HomeContent.swift Zone-4 ViewThatFits rewire (C5)

Before T7 (current HomeContent body):

```swift
// Track-10 T5 — Zone-5 full-width SINCE YOU WERE LAST ACTIVE.
SinceLastActiveBlock(
    items: snapshot.sinceLastActiveItems,
    onMarkAllAsSeen: {
        lastSeenCursor.markAllAsSeen(now: Date())
        reader.refresh()
    }
)
```

After T7:

```swift
// Track-10 T7 — Zone-4 2-col `SINCE ‖ YOU'RE ON` per master spec
// §2 scope lock #5. T6 ViewThatFits Zone-3 precedent reuse: wide
// window → HStack 2-col; narrow → VStack stacked, SINCE above
// YOU'RE ON (priority order baked into child sequence).
ViewThatFits(in: .horizontal) {
    HStack(alignment: .top, spacing: LeafSpace.md) {
        SinceLastActiveBlock(
            items: snapshot.sinceLastActiveItems,
            onMarkAllAsSeen: {
                lastSeenCursor.markAllAsSeen(now: Date())
                reader.refresh()
            }
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)

        YoureOnBlock(
            session: snapshot.currentSession,
            gitDelta: snapshot.gitDelta
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    VStack(alignment: .leading, spacing: LeafSpace.xl) {
        SinceLastActiveBlock(
            items: snapshot.sinceLastActiveItems,
            onMarkAllAsSeen: {
                lastSeenCursor.markAllAsSeen(now: Date())
                reader.refresh()
            }
        )
        YoureOnBlock(
            session: snapshot.currentSession,
            gitDelta: snapshot.gitDelta
        )
    }
}
```

`SinceLastActiveBlock` block body unchanged. T5 tests for block
body still green; only HomeContent callsite migrates (no T5 spec
change required).

### 3.5 Test coverage (~25-30 new tests)

| File | Target | Tests |
|---|---|---|
| `CurrentTaskSessionTests.swift` | LeafCoreTests | Codable round-trip · Equatable · Hashable · init shape · `[String]` openFiles round-trip — **4 tests** |
| `YoureOnRowComposerTests.swift` | LeafCoreTests | composeTaskLine variations (LEAF-only / branch-only / +N-ahead-only / all-three / all-nil) · composeSessionLine (formatted ms→HH:mm + focused min branches) · composeFilesLine (empty / 1 / 2 / 3 / dedup) · formatSessionStart timezone fixture · formatFocusedMin <1h / ≥1h / 0 / large · a11yLabel composition — **15-18 tests** |
| `ProdInsightsCurrentTaskSessionTests.swift` | LeafCorePrivateTests (moat — gitignored) | Happy path (Xcode workspace) · nil taskIdentity → nil bundle · nil workspacePath → nil bundle · nil foregroundBundleID → nil bundle · per-IDE dispatch matches Xcode path-walk · per-IDE dispatch matches VSCode workspace_root · per-IDE dispatch matches JetBrains workspace_root · no-match-today fallback to 00:00 · openFiles cap 3 · openFiles dedup by basename · **`test_currentTaskSession_OpenFilesAreBasenamesOnly_NoSentinelLeak`** (Q8 sentinel — feed doc_path with `LEAKED_SENTINEL_T7_DOC_PATH` in directory portion → assert basenames don't contain "/" AND don't contain sentinel) — **10-12 tests** |
| `InsightsSnapshotTests.swift` | LeafCoreTests | Extend existing — +1 test for `currentSession` defaulted field round-trip (mirrors T6 `memberCount` / `activeTeammates` precedent) — **+1 test** |

Total: ~30-35 new tests.

### 3.6 Privacy walkback grep (gate 4)

T7 file set narrow scope:

- `Packages/LeafCore/Sources/LeafCore/Insights/CurrentTaskSession.swift`
- `Packages/LeafCore/Sources/LeafCore/Home/YoureOnRowComposer.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift` (extension only)
- `Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift` (defaulted field add)
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+CurrentTaskSession.swift`
- `Leaf/Models/InsightsReader.swift` (composition site)
- `Leaf/Views/Window/Home/HomeView.swift` (post-extraction)
- `Leaf/Views/Window/Home/HomeContent.swift` (new file)
- `Leaf/Views/Window/Home/Blocks/YoureOnBlock.swift`

`grep -nE "absolute_path|full_comment_body|raw_email|notes_body|email_subject|note_body|file_contents|raw_prompt|tool_input|tool_response|response_body|prompt"` across this set must return zero hits (excluding doc-comment intent-statements listing forbidden fields).

### 3.7 Substrate-purity diff invariants

| Invariant | T7 ship |
|---|---|
| `ShareEventTypeRegistry.swift` diff | 0 lines |
| SQLCipher migrations diff | 0 lines (30 tables preserved) |
| MCP tools | 15 (unchanged) |
| `event_kind` registry | 198 (frozen) |
| New public protocol methods | +1 (`currentTaskSession`) |
| New public value types | +1 (`CurrentTaskSession`) |
| New public LeafCore helpers modules | +1 (`YoureOnRowComposer`) |
| Defaulted-init field additions | +1 (`InsightsSnapshot.currentSession`) — 13th iteration |
| Sentinel-injection RelayBodyLeakageTests delta | 0 (§6 EXEMPT preserved) |
| Moat unit test delta | +1 (basename invariant lock) |
| HomeView.swift LOC | 309 → ~175 (HomeContent extracted) |
| HomeContent.swift LOC | NEW ~115-120 (Zone-4 ViewThatFits 2-col) |
| YoureOnBlock.swift LOC | NEW ≤180 |
| YoureOnRowComposer.swift LOC | NEW ~70-90 |
| `InsightsReader.refresh()` SQL/protocol calls | 27 → 28 (+1 monotonic) |

---

## 4. Implementation commits (5 atomic implementation + 1 SHIPPED docs)

| # | Subject |
|---|---|
| C1 | `feat(GUN-50): CurrentTaskSession value type + currentTaskSession() protocol + tests (Track-10 T7)` |
| C2 | `feat(GUN-50): ProdInsights+CurrentTaskSession moat impl + per-IDE dispatch + basename invariant test (Track-10 T7)` |
| C3 | `feat(GUN-50): InsightsSnapshot.currentSession + InsightsReader.refresh() composition (Track-10 T7)` |
| C4 | `refactor(GUN-50): extract HomeContent.swift from HomeView (Track-10 T7)` |
| C5 | `feat(GUN-50): YoureOnBlock + YoureOnRowComposer + Zone-4 ViewThatFits 2-col rewire (Track-10 T7)` |
| C6 | `docs(GUN-50): SHIPPED — Track-10 T7 phase spec landing + current-state update` |

Stage 6 review may emit a fix-bundle commit between C5 and C6
(T2/T5/T6 precedent — a11y or composer NITs caught by independent
reviewer; rolled inline before SHIPPED docs commit).

**Build-green invariant per commit:**
- C1: types pure-Swift; LeafCore tests pass.
- C2: moat impl with default-extension fallback; LeafCorePrivate tests pass; UI consumes still-nil bundle (no behavior change).
- C3: snapshot field defaulted; InsightsReader composition site refactored; reader returns full bundle via moat; UI still doesn't consume bundle (no behavior change).
- C4: pure file move; HomeView/HomeContent both compile against unchanged public surface; visual output identical.
- C5: new view + Zone-4 rewire consumes bundle; first visible UX change.
- C6: docs-only; tip commit for SHIPPED.

---

## 5. Verification gates (master spec §7.2)

| # | Gate | Target |
|---|---|---|
| 1 | 5/5 xcodebuild Debug schemes BUILD SUCCEEDED | ✓ |
| 2 | SPM tests green (baseline ~3035 + ~30-35 new) | ✓ |
| 3 | `just check-tokens` 3-tier clean (BASE / MIGRATION / RETIRED) | ✓ |
| 4 | Privacy walkback grep narrow T7 scope | 0 forbidden field hits (excl. doc-comments) |
| 5 | Sentinel-injection | EXEMPT per §6; +1 moat unit test passes |
| 6 | HomeView.swift LOC ≤ 310 | ~175 actual (post HomeContent extraction) |
| 7 | `InsightsReader.refresh()` SQL/protocol calls monotonic | 27 → 28 (+1) |
| 8 | No new SQLCipher migrations | empty diff `Packages/LeafCore/Sources/LeafCore/DB/` |
| 9 | No new ShareEventTypeKey entries | empty diff `ShareEventTypeRegistry.swift` (registry 198) |

Manual smoke (Дима driver post-launch, post-Stage 6 review) per
master spec §7.3 Zone 4:

- Open Leaf with an active Xcode workspace on a feature branch
  (e.g., `feature/GUN-50-track-10-T7-youre-on-anchor`) → YOU'RE ON
  block renders `GUN-50 · feature/GUN-50-... · +N ahead of main`
  task line; "Started HH:MM" matches first Xcode focus in workspace
  today; "Xh Ym focused so far" matches per-task time; "Open files:"
  shows 3 most-recent file basenames.
- Switch to a VSCode workspace mid-day → "Started" updates to
  switch time (per-IDE dispatch Q5).
- Close Xcode, only Terminal active → block renders empty state
  copy "No active task identified — ...".
- Narrow window → ViewThatFits collapses to VStack; SINCE stays
  above YOU'RE ON (priority order).

---

## 6. Dependencies + carry chain

**T7 depends on (already shipped):**
- T2 SHIPPED — `GitDeltaSnapshot` + `currentTaskIdentity()` + `currentWorkspacePath()` + `TaskIdentity` 5-field shape.
- T5 SHIPPED — `SinceLastActiveBlock` Zone-5 callsite (T7 migrates it inside ViewThatFits).
- T6 SHIPPED — ViewThatFits Zone-3 2-col precedent reuse; `TeamNRowComposer` pure-helper LeafCore module pattern; defaulted-init 13th iteration.
- Track-9 T1 SHIPPED — `xcode_active_doc_changed.doc_path` + `vscode_active_doc_changed.workspace_root` + `vscode_active_doc_changed.file_basename` + `jetbrains_recent_project_observed.workspace_root` allowlisted payloads; storage-side `RelayBodyLeakageTests` walkback lineage.
- `ProdInsights+CurrentTaskIdentity.swift` moat — Stage 1 `lastActivity(bundleID: nil)` foreground bundle resolution pattern (moat-internal helper reuse).

**T7 emits to (downstream):**
- **T8 RECAP+EOD** — does NOT consume YOU'RE ON substrate. T8 uses existing protocol APIs (todayMetrics, linearActivity, githubActivity, inboxItems, openBlockers, recentWhereStopped). Independent.
- **T9 polish + wrap** — sweep applies to new T7 files; LOC gate 6 verified.
- **Phase 5.4 team presence** — orthogonal; no T7 surface dependency.

**T7 emits carries:**

- **C-T7-1** — Branch deletion staleness (Track-9 §9.1 C-8 lineage). If branch referenced by `taskIdentity.branch` is deleted but still last-seen in events DB, YOU'RE ON shows stale branch name. Same carry that exists for ResumeHeroBlock. Defer to v1.1.
- **C-T7-2** — JetBrains file-level openFiles surface — JetBrains substrate provides workspace-level only (`jetbrains_recent_project_observed`). When JetBrains plugin extension lands (Layer D V2) emitting per-file events, extend `collectRecentBasenames`. Defer to Layer D V2.
- **C-T7-3** — `refBasename(_:)` rule-of-three extraction. T2 ResumeHeroBlock has file-local copy; T7 YoureOnRowComposer has own static. When a third caller appears (T8 RECAP/EOD might compose branch-relative refs), extract to shared LeafCore helper. T9 polish carry.
- **C-T7-4** — Workspace path-walk caching. Per-IDE dispatch step in moat may invoke `WorkspacePathResolver`-style `.git`-discovery on multiple events per refresh tick. If profiling shows hot path, memoize per refresh. Defer to v1.1 if metrics demand.
- **C-T7-5** — Per-task focused-min derivation method choice. Spec leaves moat impl flexibility (LAG-window attention walk OR focusSessions filter). Reconcile to single canonical approach during impl if cross-spec inconsistency emerges.
- **C-T7-6** — Calendar / timezone injection consistency. `composeSessionLine` takes `calendar: Calendar` for testability; production callsite uses `@Environment(\.calendar)`. Verify SwiftUI `\.calendar` env value matches `Calendar.current` in production runtime.
- **C-T7-7** — Settings → branch parsing sub-section (out-of-scope CTA target referenced in master spec §3.6 / §8 "Out of scope"). If user demand emerges for branch-parsing customization (e.g., custom LEAF-ID regex), spawn own substrate phase.
- **C-T7-8** — `vscode_active_doc_changed` `file_basename` payload presence — verified via parser comment in Discovery; if Track-9 T1 emission contract evolves, openFiles fallback to `doc_path` basename triggers. Monitor.

### 6.1 Post-ship local moat hot-fixes (2026-05-23 — landed local-only, NOT in git)

After SHIPPED, manual smoke on author's Mac surfaced three UX gaps for the
**Claude Code Terminal-only workflow** (user lives in `claude` CLI inside
Terminal/iTerm/Ghostty, no Xcode/VSCode/JetBrains foreground today). All
three patches landed in **gitignored** `LeafCorePrivate` moat files; they
work locally but do NOT propagate to other team members until promoted to
a proper substrate phase. **Master spec §9.2 mirrors these as
C-T10-EMIT-T7H1..H3 for Track-9 wrap visibility.**

- **C-T7-H1 (GUN prefix LinearID resolution)** — `ProdInsights+CurrentTaskIdentity.swift:39`
  `knownPrefixes` hardcoded to `Set<String>(["LEAF"])`. Branches like
  `feature/GUN-50-...` resolved with `linearID = nil`, so RESUME hero and
  YOU'RE ON task line dropped the leading ID. Hot-fix: extended to
  `["LEAF", "GUN"]`. **Proper resolution** — Phase 4.7.A's
  `LinearIDPrefixCache` v1.1 (live workspace prefix sync from Linear API)
  per existing comment. Affects all surfaces consuming `TaskIdentity` (RESUME,
  YOU'RE ON, YOU·NOW substrate, RouteCoordinator Linear CTA).

- **C-T7-H2 (aiCollaboration fallback for sessionStart)** —
  `perIDEEarliestEventTodayMatchingWorkspace` returned nil when no
  Xcode/VSCode/JetBrains attention event matched workspace today. Composer
  fell back to today midnight (`Started 00:00`) and `focusedMinSoFar = 0`,
  collapsing the session line to "Started 00:00" with no suffix —
  semantically vacuous for Terminal-only users. Hot-fix: extended dispatch
  with a second SQL pass over `signal_type='aiCollaboration'` events today
  where `payload_json.cwd` matches workspace (new `cwdWorkspaceMatches`
  helper accepts canonical / parent / tilde / ancestor shapes). Earliest
  matching aiCollaboration event becomes `sessionStartMs`. **Proper
  resolution** — first-class "Claude Code workflow" tier in master spec §3.6
  contract (currently silent about non-IDE sources). Future phase: extend
  `CurrentTaskSession` with a `sessionSource: enum {ide, aiCollaboration,
  fallback}` field so composer can render "Started 09:18 via Claude Code"
  for transparency.

- **C-T7-H3 (terminal-family dwell for focused-min)** —
  `focusedMinDwellSince(bundleID:)` signature took a single bundle ID. The
  aiCollaboration-fallback path (C-T7-H2) yields a bundleID that may be the
  agent itself (`tech.gundem.leaf.agent`) — wrong substrate for dwell sum.
  Hot-fix: signature changed to `focusedMinDwellSince(bundleIDs: [String])`,
  SQL `WHERE bundle_id IN (?, ?, ...)`, and aiCollaboration fallback returns
  `terminalFamilyBundleIDs UNION {loggedBundleID}` covering Terminal,
  iTerm2, Ghostty, Warp, Alacritty, Kitty, WezTerm, Hyper. Single-IDE path
  unchanged (returns `[bundleID]` wrapped). **Proper resolution** — same as
  C-T7-H2 (first-class Claude Code workflow tier). `terminalFamilyBundleIDs`
  Set could live in shared `IDEFamilyClassifier` registry next to
  `vscodeFamilyBundleIDs` / `jetbrainsBundleIDs` for consistency.

**Common follow-up phase** (proposal — not yet specced): **"Claude Code
workflow first-class in YOU'RE ON"** — own brainstorm + spec session
elevating all three hot-fixes to canonical substrate. Carries:
- Promote `knownPrefixes` to live `LinearIDPrefixCache` (v1.1 trigger).
- Add `sessionSource` enum to `CurrentTaskSession` value type.
- Hoist `terminalFamilyBundleIDs` to `IDEFamilyClassifier.terminalFamilyBundleIDs`.
- Add `sentinel-injection` regression coverage for aiCollaboration `cwd`
  → workspace match (currently moat-tested only via happy path).
- Spec-level decision: should aiCollaboration fallback win OVER IDE match
  in any scenario (e.g. user opens Xcode briefly to grep something but is
  actually working in Claude Code)? Current dispatch IDE-first is correct
  default but worth questioning.

---

## 7. ADR-010 / sentinel-injection — T7 EXEMPT

Per master spec §6 verbatim:

> "T7 — `openFilesInCurrentWorkspace` reads existing T1 (Track-9)
> allowlisted basenames; existing Track-9 T1 sentinel walks
> `vscode_active_doc_changed.workspace_root` cover."

Q9 amendment: T7 ships bundled `currentTaskSession()` rather than
separate `openFilesInCurrentWorkspace(limit:)`. Same EXEMPT
classification — bundle reads same allowlisted payloads, transforms
to basenames at moat boundary via `NSString.lastPathComponent`.

**T7 adds 1 lightweight moat unit test** (does NOT escalate §6
classification):

`Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsCurrentTaskSessionTests.swift`:
```swift
@Test func test_currentTaskSession_OpenFilesAreBasenamesOnly_NoSentinelLeak() throws {
    let sentinel = "LEAKED_SENTINEL_T7_DOC_PATH"
    let leakingDocPath = "/Users/\(sentinel)/leaf/Foo.swift"
    // Seed event row with leakingDocPath as xcode_active_doc_changed.doc_path
    // ...
    let session = try insights.currentTaskSession()
    // Field-by-field invariant: each basename has no slash, no sentinel
    for basename in session?.openFiles ?? [] {
        #expect(!basename.contains("/"))
        #expect(!basename.contains(sentinel))
    }
    // Belt-and-suspenders Mirror reflection guard
    let mirrorDump = String(describing: session)
    #expect(!mirrorDump.contains(sentinel))
}
```

Privacy walkback grep narrow scope (T7 file set per §3.6 list): 0
hits for forbidden fields. Storage-side walkback discipline
unchanged — Track-9 T1 `RelayBodyLeakageTests` lineage already
covers `vscode_active_doc_changed.workspace_root` / Xcode doc_path /
JetBrains workspace_root storage-side.

---

## 8. Out of scope

- **Phase 5.4 team presence** (orthogonal, owns own track).
- **JetBrains per-file openFiles** — requires plugin substrate
  (Layer D V2), not in Track-10. Carry C-T7-2.
- **Per-task focused-min full session-boundary parity** — T7 ships
  cheaper LAG-window dwell sum; full focusSessions-grade per-task
  derivation is a v1.1 enhancement if accuracy gap surfaces.
- **Branch staleness detection** — Track-9 §9.1 C-8 lineage carry.
- **Workspace path-walk caching** — micro-optimization, defer to
  metrics-driven v1.1.
- **AI narrative** ("what is the user on?" composed prose) — v1.1
  BYOK additive track.
- **Tappable openFiles row** (deep-link to file in IDE) — not
  required by master spec mockup; carry to v1.1 if user demand.
- **Configurable openFiles cap** — master spec §3.6 contract is 3;
  configurable parameter YAGNI for T7.
- **Settings → branch parsing sub-section** — referenced as
  out-of-scope CTA target in master spec §3.6 empty state; no
  Settings sub-section exists today; would be own substrate phase
  if user demand emerges.
- **Master spec §5.4 API surface row swap** — emit-list amendment
  applied at T9 wrap; T7 spec lists in §9 below.

---

## 9. Master spec amendments (T9 wrap emit list)

1. **§5.4 inventory** — replace row
   `openFilesInCurrentWorkspace(limit:)` with
   `currentTaskSession() throws -> CurrentTaskSession?` returning
   bundled `CurrentTaskSession` value type. Add row `CurrentTaskSession`
   value type with `taskIdentity / sessionStartMs / focusedMinSoFar /
   openFiles` fields. Add row `YoureOnRowComposer` LeafCore helpers
   module.
2. **§6 EXEMPT row** — keep T7 EXEMPT classification verbatim; add
   note "1 moat unit test (basename-only invariant lock) ships
   alongside; does NOT escalate §6 classification to
   `RelayBodyLeakageTests` walkback."
3. **§7.2 gate 6 baseline** — actual T7 ship leaves `HomeView.swift`
   at ~175 LOC (HomeContent extracted); new `HomeContent.swift`
   at ~115-120 LOC; both well under 310 cap. Document HomeContent
   extraction as a Track-10 LOC defense move applied at T7 instead
   of T9.
4. **§7.2 gate 7 baseline correction** — T6 ended at 27 SQL/protocol
   calls (not 26 as plan §11.1 estimated). T7 ends at 28 (+1
   monotonic).
5. **§3.6 wording amendment** — "+5 ahead of main" mockup retained
   verbatim (compact for narrow Zone-4 column); T2 §4.8 "5 commits
   ahead of main" verbose wording applies to RESUME hero only
   (wider context). Per-block wording divergence acceptable.
6. **§4 T7 substrate paragraph correction** — "new helper
   `openFilesInCurrentWorkspace(limit:)`" → "new bundled method
   `currentTaskSession() throws -> CurrentTaskSession?`" returning
   composed bundle (Q9 amendment).
7. **§2 scope lock #5 carry close** — Zone-4 2-col `SINCE ‖ YOU'RE ON`
   shipped at T7 SHIPPED tip; T5's interim full-width SinceLastActiveBlock
   callsite migrated to ViewThatFits 2nd child position. T5 block
   body unchanged.

T9 wrap session applies these amendments inline to master spec file.

---

## 10. References

- Master spec: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` (§4 T7 · §3.6 · §5.4 · §5.5 · §6 · §7.2).
- T2 RESUME hero spec: `docs/superpowers/specs/2026-05-22-track-10-T2-resume-hero.md`.
- T5 SINCE spec: `docs/superpowers/specs/2026-05-22-track-10-T5-since-last-active.md`.
- T6 TEAM·N spec: `docs/superpowers/specs/2026-05-23-track-10-T6-team-n-broader-pulse.md`.
- LEAF-NN / GUN-NN tracking convention: `docs/conventions/leaf-id-tracking.md`.
- Track-9 T1 substrate (`xcode_active_doc_changed.doc_path` /
  `vscode_active_doc_changed.workspace_root,file_basename` /
  `jetbrains_recent_project_observed.workspace_root` allowlist +
  sentinel walks).
- `.claude/shared/architecture.md` — substrate baseline (registry
  198 · 30 SQLCipher tables · 15 MCP tools — unchanged through T7).
- `.claude/shared/conventions.md` — 8-stage per-phase workflow.
- ADR-010 walkback discipline — sentinel-injection lineage.
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+CurrentTaskIdentity.swift` — foreground-bundle resolution pattern (moat-internal helper reuse).
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+TodayMetrics.swift:103` — LAG-window attention transitions SQL precedent for per-task focused-min walk.
