# Track 7 — P3 (P7 в master spec) · Work State card + detail · Design Spec

**Status:** Draft (2026-05-17). Promoted to "Active" after user review gate (Stage 3) closes.
**Stage 1 discovery:** Explore subagent — D3 detection tables (M014), DetectorPipeline / DetectorScheduler / QueryEngine surfaces, DerivedInsights protocol + InsightsSnapshot, LeafTab + SurfaceCard + SurfaceDetailLayout primitives, HomeView wire-up; main session cross-check verified file paths and signatures (subagent fabricated `TodaySection.swift` as separate file — it is a private struct inside HomeView.swift; subagent referenced `SurfaceCardCompact` — not in P1 baseline, that primitive landed in P2-collapsed).
**Master spec reference:** `2026-05-17-track-7-ui-surface-polish-design.md` §6 (Work State card + detail), §9.1 (DerivedInsights additions), §12 P7 (phase scope).
**P1 template reference:** `ClaudeCodeSurfaceCardViewModel` (namespace-enum stateless mapper) + `ClaudeCodeDetailViewModel` (`@MainActor @Observable` class, detached Task SQL pipeline, 4-case State enum). P3 follows this shape for Work State.
**Authors:** Dmitrii + Claude.

---

## 1. Goal & scope

Promote Work State from "Track-1 D3 detectors write to 5 tables, MCP exposes 3 structured tools" to **a Home card always visible between Today and Surfaces sections + drill-down detail screen with a second LeafTab over four sub-categories (Decisions / Questions / Blockers / Where Stopped)**. Always on (no enable toggle), substrate-only (zero new event_kinds, zero migrations, zero MCP tools, zero schema columns).

Fitness function for the phase:

1. **Substrate-only coupling.** D3 tables (`decisions` / `open_questions` / `blockers` / `where_stopped_log`) become readable through four new typed `DerivedInsights` methods. No new MCP tools (existing 3 structured tools — `leaf_get_decision` / `leaf_current_work` / `leaf_query_activity` — already cover MCP consumers). No schema changes.
2. **ADR-010 walkback preserved.** New view code renders only the columns already capped upstream by detectors (`excerpt`, `topic_keywords_json`, `wip_signals_json`, `confidence`, `*_at_ms`, ref strings). No raw event body field reads. New `WorkStatePayloadWalkbackTests` extends the P2-collapsed Mirror-based fence to cover the 5 new payload types.
3. **Card always visible.** No enable toggle, no default-OFF gating — D3 detection is scheduled (always-on substrate). Card renders "All clear" headline when both counts are zero and no decision exists in the last 7 days.
4. **Single-session sequential implementation.** 8-stage workflow inside this one Claude session. TDD per step, sequential discipline, atomic commits per step.
5. **One acceptance smoke passes.** A–G smoke on author's Mac per §7.1 once detectors have populated some D3 rows.

**In scope:** 1 card view-model (stateless namespace enum), 1 detail view-model (`@Observable` class), 1 card composite (`WorkStateCard`), 1 detail screen (`WorkStateDetailScreen`), 4 sub-tab row views, 1 `WorkStateRoute` Hashable marker type, 1 navigationDestination wire-up in `HomeContent`, 1 card placement between TodaySection and SurfacesSection, 4 new `DerivedInsights` protocol methods + default-extension stubs, 5 new public value types (structs) + 4 new public enums in LeafCore, 1 `InsightsSnapshot.workState` optional field, 8 new test files in `Packages/LeafCore/Tests/LeafCoreTests/`, 1 extension to `WorkStatePayloadWalkbackTests` to cover new types.

**Out of scope (hard exclusion list, mirrors master spec §1 + P2-collapsed §1 + P3-specific carve-outs):**

- New event_kinds, migrations, MCP tools, schema columns, ShareEventTypeKey registry additions.
- Clickable cross-link navigation on context refs (Slack thread / Linear issue / GitHub PR). Renders as inline text `"→ {ref}"` + tooltip via `.help(...)` only; tap is no-op in v1.0. Tap-routing deferred to P11 / Layer B drill-down phases (P8-collapsed).
- Cross-provider thread visualization (`get_cross_provider_thread` MCP tool surfacing) — explicit master spec §1 exclusion preserved.
- AI-narrative / "describe my Work State in words" — v1.1 BYOK track.
- Modifying any detector code (`DecisionDetector` / `OpenQuestionDetector` / `BlockerPatternDetector` / `LinearStuckScanner` / `WhereStoppedDeriver`) or `DetectorPipeline` / `DetectorScheduler`. Substrate frozen for this phase.
- Modifying M014 migration / D3 schema. Tables read as-is.
- Modifying MCP tool surface (`leaf_get_decision` / `leaf_current_work` / `leaf_query_activity`). MCP consumers stay on existing endpoints.
- New token primitives, new composites, new layouts. P3 is a pure consumer of D1 token set + existing primitives (`LeafCard` / `LeafTab` / `LeafSection` / `LeafIcon` / `LeafEmptyState` / `LeafBanner` / `LeafDivider`).
- LivePresenceWidget click-through (Linear / GitHub / Slack drill-downs) — P8-collapsed.
- Calendar carve-out logic — P11 tail concern.

---

## 2. Decisions locked (brainstorm carry-over)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Card primitive** | New `WorkStateCard` composite (not reuse `SurfaceCard`) | `SurfaceCard` is generic over `Spark: View` and tied to `HomeSurface` enum via `LeafIcon(surface:)` switch. Work State has no spark (derived D3 data, not 7-day capture intensity) and is semantically not a capture surface. ~35 LOC clean composite avoids forced generic-Spark = `EmptyView` + enum extension. |
| **Detail scaffold** | Bypass `SurfaceDetailLayout`, compose directly from `LeafTab` + `LeafCard` + `LeafSection` | Master spec §6.2 wording "Same `SurfaceDetailLayout` scaffold" diverges from the primitive's actual shape: `chartBlock` wraps content in `LeafCard{ frame(height: 112) }` — wrong shape for a sub-tab strip and per-tab varying content. Work State has 5 sections (range-tab / headline / sub-tab / aggregates / list) vs primitive's 4. Direct composition mirrors the primitive's visual rhythm without API forking. ~120 LOC view. |
| **Navigation routing** | New `WorkStateRoute` Hashable type, second `navigationDestination(for:)` on `HomeContent`'s NavigationStack | `RouteCoordinator.swift:22-23` comment explicitly anticipates this: "WorkStateCard etc. would push their own destination types in P7+". Avoids polluting `HomeSurface` enum with a non-surface case. |
| **Default sub-tab** | `.questions` | Master spec §6.2 mockup default; "open questions" are blocking attention, highest signal value for the "what state am I in" question. Decisions tab is 1-tap away. |
| **Card "Last decision" data source** | `InsightsSnapshot.workState: WorkStateSummary?` optional field, assembled by `InsightsReader` snapshot builder (LeafCorePrivate side) from 4 protocol method results | Mirrors P2-collapsed `<surface>Activity` optional pattern. `nil` → card renders "All clear" via stateless mapper. Snapshot builder extension lives in private moat; for public substrate it's enough that the field exists. |
| **Cross-link affordance** | Inline text `"→ {ref}"` with `.help(...)` tooltip, no tap target | Master spec §6.3 prohibits clickable navigation in v1.0. Pills/badges read as clickable — wrong affordance. Inline text + tooltip preserves intent honestly. |
| **Aggregates per sub-tab** | Compute in detail view-model from already-loaded `[Decision] / [OpenQuestion] / [Blocker] / [WhereStoppedSnapshot]` (pure Swift derivation) | Per master spec §6.3 each sub-tab shows Count + 1 derived stat (Avg confidence / Avg age / Open by `target_kind` / Last snapshot age) — all derivable from the displayed top-30 list. Zero extra DB roundtrip. |
| **DerivedInsights protocol additions** | 4 methods exactly per master spec §9.1 (no 5th `workStateSummary()`) | Stay strictly within master contract. `WorkStateSummary` assembly happens at snapshot-build time inside `InsightsReader` (LeafCorePrivate) by calling the 4 existing methods; for public substrate / Stub conformers, default extensions return `[]` / `.empty` → naturally degrades to "All clear" card without throwing. |
| **List partition rule** | Questions / Blockers tabs show open partition first (sorted DESC by start/open time), then resolved partition (sorted DESC by resolve time); combined cap of 30 | Master spec §6.3 row caps. View-model splits in-memory after fetch. |
| **Empty state per sub-tab** | LeafEmptyState centered with brand-leaf icon, per-sub-tab copy (Decisions: "No decisions logged yet"; Questions: "No open questions"; Blockers: "No blockers"; Where Stopped: "No work-state snapshots yet") | Mirrors `ClaudeCodeDetailScreen.emptyState` shape; brand-neutral copy. |
| **Tests** | 8 new test files in `Packages/LeafCore/Tests/LeafCoreTests/`, ≥30 cases; plus `WorkStateSurfaceCardPayloadWalkbackTests.swift` extending P2-collapsed Mirror fence | Per P2-collapsed precedent (90 net-new tests for 5 surface payloads). Smaller scope here — ~30+ cases. |
| **Commit decomposition** | 8 atomic commits, mirroring P2-collapsed Phase A→J shape | Per Stage 4 plan; each commit leaves build + tests green. |

---

## 3. Card contract (`WorkStateCard` + `WorkStateCardViewModel`)

### 3.1 Visual contract

```
┌─ Work State                              ▸ ─────────────────┐
│  3 open questions · 1 blocker                              │   ← headline (LeafType.title.medium / LeafColor.text.primary)
│  Last decision: "use SQLite WAL for cross-process"         │   ← sub-line (LeafType.body.regular / LeafColor.text.secondary)
└────────────────────────────────────────────────────────────┘
```

Layout: `HStack(alignment: .center, spacing: LeafSpace.md) { LeafIcon · VStack{headline · subLine} · Spacer · chevron }`.

- Icon: `LeafIcon(systemName: "checkmark.bubble.fill", size: .lg, tint: LeafColor.accent.primary)` — generic "thought state" glyph. Not in `LeafIcon(surface:)` since Work State is not a `HomeSurface`.
- Wrapped in `LeafCard(variant: .raised, padding: .regular)` inside `Button(action: onTap) { ... }.buttonStyle(.plain)`.
- Whole card is tap target — `onTap` triggers `coordinator.pushHomeWorkState()` (new method).
- Accessibility: `.accessibilityElement(children: .ignore) + .accessibilityLabel("Work State: <headline>, <subLine>") + .accessibilityAddTraits(.isButton)`.

### 3.2 Headline composition rules

Computed from `WorkStateSummary` by `WorkStateCardViewModel`:

| `openQuestionsCount` | `openBlockersCount` | Headline |
|---:|---:|---|
| 0 | 0 | `"All clear"` (LeafColor.text.secondary, single fragment, neutral tone) |
| N (≥1) | 0 | `"{N} open question{s}"` |
| 0 | M (≥1) | `"{M} blocker{s}"` |
| N (≥1) | M (≥1) | `"{N} open question{s} · {M} blocker{s}"` |

Plural rule: standard English `count == 1 ? "" : "s"`.

### 3.3 Sub-line composition rules

| Condition | Sub-line | Color |
|-----------|----------|-------|
| `lastDecisionExcerpt` is nil OR empty | omitted entirely | n/a |
| `lastDecisionExcerpt` present AND `lastDecisionAgeMs` ≤ 7d | `Last decision: "{excerpt, max 60 chars + …}"` | `LeafColor.text.secondary` |
| `lastDecisionExcerpt` present AND `lastDecisionAgeMs` > 7d | same shape | `LeafColor.text.tertiary` (greyed — stale) |

Truncation rule: trailing ellipsis (`String.prefix(60) + "…"`) once `count > 60`. Single line, `lineLimit(1)`, `truncationMode(.tail)`.

### 3.4 View-model shape (stateless namespace enum)

```swift
enum WorkStateCardViewModel {
    static func state(snapshot: InsightsSnapshot) -> WorkStateSummary
}
```

`WorkStateSummary` is the public LeafCore type from §5.1; it carries the 4 fields driving headline + sub-line. Mapper rule:

- `snapshot.workState == nil` → `WorkStateSummary.empty` (renders "All clear")
- `snapshot.workState != nil` → returns `snapshot.workState!`

Single-type model — there is no separate "card payload" struct. `WorkStateSummary` is both the snapshot field and the card mapper output. `HomeContent` already gates rendering on `InsightsReader.State == .loaded`, so the mapper signature takes a non-optional `InsightsSnapshot` (no `.loading` state at the card layer). P1/P2 namespace-enum pattern preserved (stateless, SwiftUI re-evaluates per body pass).

---

## 4. Detail contract (`WorkStateDetailScreen` + `WorkStateDetailViewModel`)

### 4.1 Visual contract

```
┌─ Work State detail (NavigationStack push) ──────────────────┐
│  [Today][Week*][Month]                                      │   ← range LeafTab (P1 DetailRange)
│  3 open questions · 1 blocker · 12 decisions               │   ← headline (LeafType.title.large)
│  ─────────────────────────────────────────────────────── │
│  [Decisions][Questions*][Blockers][Where Stopped]          │   ← sub-tab LeafTab
│  ─────────────────────────────────────────────────────── │
│  Aggregates (per active sub-tab):                          │
│    Questions tab: Open count · Avg age · Top sources       │   ← LeafCard wrapper
│  ─────────────────────────────────────────────────────── │
│  List (per active sub-tab):                                │
│    ┌─ Question row ──────────────────────────────────────┐ │
│    │ "Should we use AES-GCM or ChaCha20?"               │ │
│    │ opened 2h ago · 2 alternatives · → LEAF-142        │ │
│    └────────────────────────────────────────────────────┘ │
│    ... (up to 30 rows)                                     │
└────────────────────────────────────────────────────────────┘
```

Direct composition (NOT `SurfaceDetailLayout`):

```swift
ScrollView {
    VStack(alignment: .leading, spacing: LeafSpace.xl) {
        rangeTabStrip           // LeafTab over DetailRange.allCases
        headlineBlock           // VStack { Text(headline) }
        subTabStrip             // LeafTab over WorkStateSubTab.allCases
        aggregatesBlock         // LeafCard with per-sub-tab summary
        listBlock               // VStack of per-sub-tab row views
    }
    .padding(LeafSpace.xxl)
}
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
.navigationTitle("Work State")
```

### 4.2 Headline composition

Computed per active sub-tab fan-out — show 3 segments regardless of active tab so user has full picture:

```
"{Q} open question{s} · {B} blocker{s} · {D} decision{s}"
```

Each segment dropped if zero (no `"0 open questions"`). All-zero fallback: `"Nothing to show — D3 detectors have not produced anything for {range}"`. Range-aware (the period segment shows the active range).

Counts derived from already-loaded payload:
- `Q = payload.questions.filter { $0.resolvedAtMs == nil }.count`
- `B = payload.blockers.filter { $0.resolvedAtMs == nil }.count`
- `D = payload.decisions.count` (no resolved/open partition for decisions)

Protocol methods return full period results (no cap at protocol layer — cap is a display concern); list block displays sorted top-30 slice (§4.3). Edge case: if a user has > 1000 open questions in period, prod impl decides on its own cap inside private SQL for performance — but defaults assume natural sub-1000 row counts and unlimited return; document as Phase 5 verification step.

### 4.3 Sub-tab content matrix

Each sub-tab shows `aggregatesBlock` + `listBlock`.

| Sub-tab | Aggregates (LeafCard) | List item row | Cap (display) |
|---------|----------------------|---------------|---------------|
| **Decisions** | `Count: {N} · Avg confidence: {conf}%` | `excerpt` (LeafType.body.regular) · `topicKeywords.joined(separator: ", ")` (LeafType.body.small / secondary) · `"{age} ago"` (LeafType.body.small / tertiary) | top 30 by `detectedAtMs DESC` |
| **Questions** | `Open: {O} · Resolved: {R} · Avg open age: {age}` | `excerpt` · `"{alternatives.count} alternatives"` (if > 0) · `contextRef` inline `"→ {ref}"` (if set) · `"{age} ago"` | top 30 — open partition first (DESC by `openedAtMs`), then resolved partition (DESC by `resolvedAtMs`); combined cap |
| **Blockers** | `Open: {O} · Resolved: {R} · By target: {Lx Linear · Gx GitHub · ...}` | `excerpt` · `"{targetKind}: {targetRef}"` · `"{age} ago"` (open age if unresolved, resolution latency if resolved) | top 30 — open first (DESC by `startedAtMs`), then resolved (DESC by `resolvedAtMs`); combined cap |
| **Where Stopped** | `Snapshots: {N} · Last: {age} ago` | `excerpt` · `wipSignals` as inline ` · `-joined string (e.g. `"5 files · 3 PRs"`) · `"{age} ago"` | top 20 by `generatedAtMs DESC` |

Caps applied **client-side** by view-model — protocol methods return full period results (see §4.2 note). Aggregates ("Count", "Open", "Resolved") are computed over the FULL returned array, not the displayed slice — so an "Open: 50" headline with only 30 visible rows is self-consistent.

Cross-link refs in Questions tab render as `"→ LEAF-142"` / `"→ owner/repo#42"` / `"→ Slack thread"` plain text + `.help(...)` tooltip exposing full ref. No tap navigation.

### 4.4 Empty state per sub-tab

If the active sub-tab's list is empty:

```swift
LeafEmptyState(
    icon: LeafIcons.brand.leaf,
    title: <sub-tab-specific>,
    description: <sub-tab-specific>
)
.frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
```

| Sub-tab | Empty title | Empty description |
|---------|-------------|-------------------|
| Decisions | "No decisions logged yet" | "Decisions surface here when Leaf detects them in your activity stream." |
| Questions | "No open questions" | "Questions you've raised in chat or comments surface here when Leaf detects them. None active right now." |
| Blockers | "No blockers" | "Blocking states (waiting for review, stuck Linear issues) surface here. Nothing blocked right now." |
| Where Stopped | "No work-state snapshots yet" | "Leaf periodically captures a 'where you left off' snapshot. None recorded yet for this range." |

### 4.5 View-model shape

```swift
@MainActor
@Observable
final class WorkStateDetailViewModel {
    enum State: Equatable {
        case loading
        case loaded(WorkStateDetailPayload)
        case error(String)
    }

    private(set) var state: State = .loading
    var range: DetailRange = .default { didSet { guard range != oldValue else { return }; reload() } }
    var subTab: WorkStateSubTab = .questions
    // ... DB url / config / encryption / detached Task pipeline (mirror ClaudeCodeDetailViewModel)
    func reload()
}

struct WorkStateDetailPayload: Equatable, Sendable, Hashable {
    let decisions: [Decision]
    let openQuestionsTotal: Int       // for headline
    let questions: [OpenQuestion]     // mixed open + resolved, capped at 30
    let openBlockersTotal: Int        // for headline
    let blockers: [Blocker]           // mixed open + resolved, capped at 30
    let whereStopped: [WhereStoppedSnapshot]
}
```

Reload pipeline:
1. `task?.cancel()` + `state = .loading`.
2. Compute `interval = range.interval(now:, calendar:)` once.
3. Detached `Task.detached(priority: .userInitiated)` opens read-only DB, makes `DerivedInsightsFactory.make(database:)`, calls 4 methods in parallel via `async let` (or sequentially — they hit different tables, no contention either way), assembles `WorkStateDetailPayload`.
4. Stale-result guard: `if Task.isCancelled { return }`.
5. Errors: `if error is CancellationError { return }`; otherwise log + `state = .error("Couldn't load Work State.")`. Never crashes UI.

Note: there is no "empty" State case at the screen level (mirror of ClaudeCodeDetailScreen) — when ALL four sub-collections are empty, headline becomes "Nothing to show — ..." and each sub-tab renders its own LeafEmptyState. Screen-level `.empty` not needed.

---

## 5. Code surface (new files)

### 5.1 LeafCore — value types + protocol additions

`Packages/LeafCore/Sources/LeafCore/Home/WorkState/`:

- `WorkStateSummary.swift` — card-level summary type (4 fields per §3.4). `Equatable, Hashable, Sendable`. `static let empty`.
- `Decision.swift` — per master spec §9.2. `id: Int64`, `excerpt: String`, `topicKeywords: [String]`, `confidence: Double`, `detectedAtMs: Int64`, `sourceEventId: Int64?`. `Equatable, Hashable, Sendable`.
- `OpenQuestion.swift` — per §9.2. `id`, `excerpt`, `alternatives: [String]`, `contextRef: ContextRef?`, `openedAtMs: Int64`, `resolvedAtMs: Int64?`, `resolvedBySourceEventId: Int64?`.
- `Blocker.swift` — per §9.2. `id`, `targetKind: BlockerTargetKind`, `targetRef: String`, `blockerKind: BlockerKind`, `excerpt: String`, `startedAtMs: Int64`, `resolvedAtMs: Int64?`.
- `WhereStoppedSnapshot.swift` — per §9.2. `id`, `generatedAtMs: Int64`, `anchorEventId: Int64?`, `excerpt: String`, `wipSignals: [String]`.
- `ContextRef.swift` — sum-type enum: `.slackThread(ts: String)`, `.linearIssue(ref: String)`, `.githubPR(ref: String)`.
- `BlockerKind.swift` — domain enum with permissive fallback: `case patternBlockedOn, linearStuck, other(String)`. Free-text `blocker_kind` column in M014 schema means private prod decoder MUST map unknown strings to `.other(raw)` to avoid decode crashes when detectors emit new kinds. View-model renders `.other(raw)` by humanizing the raw string.
- `BlockerTargetKind.swift` — same fallback shape: `case linearIssue, githubPR, other(String)`. Same M014 schema reason.
- `WorkStateSubTab.swift` — `enum WorkStateSubTab: String, Hashable, Identifiable, CaseIterable { case decisions, questions, blockers, whereStopped; var id: String { rawValue }; var displayName: String { ... } }`.

`Packages/LeafCore/Sources/LeafCore/Insights/`:

- `DerivedInsights.swift` (modify) — add 4 protocol method signatures:
  ```swift
  func recentDecisions(period: DateInterval, limit: Int) throws -> [Decision]
  func openQuestions(period: DateInterval) throws -> [OpenQuestion]
  func openBlockers() throws -> [Blocker]
  func recentWhereStopped(limit: Int) throws -> [WhereStoppedSnapshot]
  ```
- Add 4 default-extension implementations returning `[]`. Stub does not need explicit overrides (default suffices).

`Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift` (modify) — add `let workState: WorkStateSummary?` field, default `nil`. Existing call-sites pass `nil` without change (default param + struct memberwise init updated). Note: this struct is `Sendable, Hashable` per P2-collapsed precedent — `WorkStateSummary` propagates that conformance.

### 5.2 Leaf app — navigation + view-models + composites + screen

`Leaf/Models/`:

- `WorkStateRoute.swift` — `struct WorkStateRoute: Hashable, Sendable {}` (zero-field sentinel marker for navigationDestination dispatch). Not an enum since it has exactly one destination; struct keeps door open for v1.1 deep-link parameters.
- `WorkStateCardViewModel.swift` — namespace enum mapper (§3.4 signature).
- `WorkStateDetailViewModel.swift` — `@MainActor @Observable final class` (§4.5 signature). Mirror file structure of `ClaudeCodeDetailViewModel.swift`.

`Leaf/Models/RouteCoordinator.swift` (modify) — add:
```swift
func pushHomeWorkState() {
    homePath.append(WorkStateRoute())
}
```
(Avoid generic `pushHome<H: Hashable>` to keep existing `pushHome(_ surface: HomeSurface)` call-sites stable.)

`Leaf/Theme/Composites/`:

- `WorkStateCard.swift` — `struct WorkStateCard: View` (no generics — no Spark slot). Takes `headline: String`, `subLineExcerpt: String?`, `subLineIsStale: Bool`, `onTap: () -> Void`. ~35 LOC.

`Leaf/Views/Window/SurfaceDetail/`:

- `WorkStateDetailScreen.swift` — main screen view (~140 LOC). Decomposes into private builders: `rangeTabStrip` / `headlineBlock` / `subTabStrip` / `aggregatesBlock` / `listBlock` / `emptyState(for:)` / `decisionsRow` / `questionsRow` / `blockersRow` / `whereStoppedRow`.

`Leaf/Views/Window/Home/HomeView.swift` (modify):
- In `HomeContent.body` insert between `TodaySection` (current HomeView.swift line 271-273) and `SurfacesSection` (line 279):
  ```swift
  WorkStateCardWrapper(snapshot: snapshot)
  ```
- Define private `WorkStateCardWrapper` struct inside HomeView.swift (parallel to existing private structs such as `HeroBlock`, `TodaySection`). Shape:
  ```swift
  private struct WorkStateCardWrapper: View {
      let snapshot: InsightsSnapshot
      @Environment(RouteCoordinator.self) private var coordinator
      var body: some View {
          let summary = WorkStateCardViewModel.state(snapshot: snapshot)
          WorkStateCard(
              headline: WorkStateHeadlineFormatter.headline(summary),
              subLineExcerpt: WorkStateHeadlineFormatter.subLine(summary, nowMs: <inject>),
              subLineIsStale: WorkStateHeadlineFormatter.subLineIsStale(summary, nowMs: <inject>),
              onTap: { coordinator.pushHomeWorkState() }
          )
      }
  }
  ```
  `WorkStateHeadlineFormatter` is a small stateless helper colocated in `Leaf/Models/WorkStateCardViewModel.swift` (or its own file) — see §5.2 follow-up. `nowMs` injected via `Date().timeIntervalSince1970 * 1000` at body call site (acceptable — UI re-evaluates per redraw; staleness boundary is daily granularity, sub-second precision not needed).
- Add second `.navigationDestination(for: WorkStateRoute.self) { _ in WorkStateDetailScreen() }` next to existing `.navigationDestination(for: HomeSurface.self)`.

### 5.3 Test files (8 new + 1 extended)

`Packages/LeafCore/Tests/LeafCoreTests/`:

1. `DecisionTests.swift` — Equatable / Hashable / Sendable smoke, init via memberwise, edge cases (empty topicKeywords, zero confidence, negative ms guard if applicable).
2. `OpenQuestionTests.swift` — same shape; explicit "open vs resolved" distinction via `resolvedAtMs == nil` check; ContextRef encoding round-trip via Equatable.
3. `BlockerTests.swift` — same shape; `BlockerKind` / `BlockerTargetKind` enum case coverage including `.other(String)` round-trip + humanization rendering helper.
4. `WhereStoppedSnapshotTests.swift` — same shape; wipSignals array handling.
5. `ContextRefTests.swift` — 3-case enum exhaustiveness, Equatable per case.
6. `WorkStateSummaryTests.swift` — `.empty` static, headline composition rule fence (4 cases per §3.2), sub-line stale boundary (7d / 7d+1ms).
7. `WorkStateSubTabTests.swift` — CaseIterable order matches mockup (`.decisions, .questions, .blockers, .whereStopped`), identifiable round-trip, displayName per case.
8. `DerivedInsightsWorkStateDefaultsTests.swift` — `StubInsights` and a dummy minimal conformer return `[]` from all 4 new methods without throwing.

`WorkStatePayloadWalkbackTests.swift` (new test file, mirrors P2-collapsed `SurfaceCardPayloadWalkbackTests`):

Mirror-based ADR-010 fence over the 6 new payload types — asserts no property label in `WorkStateSummary` / `Decision` / `OpenQuestion` / `Blocker` / `WhereStoppedSnapshot` / `ContextRef` (associated values) matches any of the 15 forbidden substrings (`message_body`, `email_subject`, `prompt`, `tool_response`, `command`, `tool_input`, `content`, `thinking`, `signature`, `iterations`, `old_string`, `new_string`, `body`, `preview`, `output`). Plus 6 positive schema lock-in assertions (one per type — assert exact property set).

Target: ≥30 test cases, +30-40 net new vs P2-collapsed 2626 baseline.

---

## 6. Cross-cutting concerns

### 6.1 ADR-010 walkback discipline

D3 detectors upstream cap `excerpt` fields at ≤500 chars (`reasoning_excerpt` / `question_excerpt` / `blocker_excerpt` / `where_stopped_log.excerpt`) and strip raw body content before INSERT. No new walkback work in P3 — read columns as-is, never enrich with raw event payload data.

`topic_keywords_json` / `alternatives_json` / `wip_signals_json` decoded as `[String]` at protocol method boundary (LeafCorePrivate prod impl decodes JSON to `[String]` before returning `Decision` / `OpenQuestion` / `WhereStoppedSnapshot`). Public type carries decoded `[String]`, never raw JSON.

Walkback test fence (test #9 above) ensures new struct property labels do not introduce forbidden substrings.

### 6.2 Default-stub behavior (no D3 data yet / iOS-future)

All 4 new protocol methods have default extensions returning `[]`. Effect:
- Fresh DB → all 4 calls return `[]` → `InsightsSnapshot.workState` is `nil` (snapshot builder is LeafCorePrivate moat — for stub conformers nothing assembles a non-nil summary).
- Card mapper `.ready(.empty)` → headline "All clear", sub-line omitted.
- Detail screen all 4 collections empty → headline "Nothing to show — D3 detectors have not produced anything for {range}".
- No throws, no error banners.

### 6.3 Sub-tab state persistence

`subTab` is view-model state, lost on `WorkStateDetailScreen` pop. Per master spec scope (no v1.0 persistence layer for UI selection), this is acceptable. Re-entry defaults to `.questions`.

`range` similarly resets to `.default` (Week) on re-entry. Mirrors `ClaudeCodeDetailViewModel.range` behavior.

### 6.4 Headline trend annotation

`WorkStateDetailPayload` does NOT carry trend data ("Δ vs previous period"). Master spec §5.4 trend rule applies to time-series detail screens (Claude Code daily tokens, Xcode daily builds). Work State counts are not time-series — comparing "3 open questions this week" to "2 open questions last week" is meaningful in v1.1 but adds noise in v1.0 (would need delta-pulled-from-resolved-and-newly-opened math). Trend omitted in P3.

### 6.5 Navigation pop-on-disable

Work State has no enable toggle, so the P2-collapsed concern "detail screen pops on toggle OFF" does not apply. Card always visible, detail always reachable.

### 6.6 Snapshot builder coupling (LeafCorePrivate side)

`InsightsReader` snapshot build (private moat) gets +1 step: after existing 12 method calls (timeInApp / focusSessions / aiActivityBreakdown / linearActivity / etc.), call:
```swift
let questions = try insights.openQuestions(period: last7d)
let blockers = try insights.openBlockers()
let recentDec = try insights.recentDecisions(period: last7d, limit: 1)
let summary = WorkStateSummary(
    openQuestionsCount: questions.filter { $0.resolvedAtMs == nil }.count,
    openBlockersCount: blockers.filter { $0.resolvedAtMs == nil }.count,
    lastDecisionExcerpt: recentDec.first?.excerpt,
    lastDecisionAgeMs: recentDec.first.map { nowMs - $0.detectedAtMs }
)
```
For P3 public substrate: `WorkStateSummary` type is the contract; the builder step is implemented in `LeafCorePrivate` (not in this branch). InsightsSnapshot.workState defaults to nil → stable behavior without private moat.

### 6.7 Just check-tokens compliance

Zero new hex / pt values introduced. All sizes derived from `LeafSpace.*` tokens. All colors from `LeafColor.*`. All typography from `LeafType.*`. Mirrors P1+P2 invariant.

### 6.8 Privacy walkback grep

Per spec §3 fitness function, post-implementation grep over P3 file scope (LeafCore types + Leaf composites + view + view-models):
```
grep -rnE "command|tool_response|tool_input|content|thinking|signature|message_body|email_subject|prompt|iterations|old_string|new_string|preview|output\." \
  Packages/LeafCore/Sources/LeafCore/Home/WorkState/ \
  Leaf/Theme/Composites/WorkStateCard.swift \
  Leaf/Views/Window/SurfaceDetail/WorkStateDetailScreen.swift \
  Leaf/Models/WorkState*.swift
```
Expected: 0 hits. (Note `body` excluded from the grep — `var body: some View` is unavoidable SwiftUI vocabulary. `body` is only forbidden as a *data* field; UI body is fine.)

---

## 7. Acceptance smoke matrix

### 7.1 A–G smoke (manual, single pass on author's Mac)

| Step | Action | Expected |
|---|---|---|
| **A** | Open Leaf → Home tab | Work State card visible between Today and Surfaces sections; headline reads either "All clear" or `"N open question[s] · M blocker[s]"` depending on D3 state |
| **B** | Wait for D3 detector pipeline tick (≤2 incremental ticks, ≤1 scheduled tick) on a workspace with recent commits / issues | Card sub-line may update with "Last decision: ..." if DecisionDetector finds anything |
| **C** | Tap Work State card | NavigationStack pushes `WorkStateDetailScreen`. Range tab strip shows `[Today][Week*][Month]`, default Week. Sub-tab strip shows `[Decisions][Questions*][Blockers][Where Stopped]`, default Questions. |
| **D** | Switch range Week → Month | All four collections reload; headline counts update; sub-tab content (the active Questions list) refreshes |
| **E** | Switch sub-tab Questions → Decisions → Blockers → Where Stopped | Aggregates block + list block re-render per sub-tab. Empty sub-tabs render LeafEmptyState with sub-tab-specific copy. |
| **F** | Hover over a Questions row with a `contextRef` (e.g. `→ LEAF-142`) | macOS tooltip appears with full reference text. Tap on the ref is a no-op (no navigation). |
| **G** | Tap chevron back / NavigationStack back gesture | Returns to Home; card still visible with current headline; tapping again re-enters detail with `range = .default` and `subTab = .questions` (sub-tab state not persisted across pop) |

### 7.2 AC-level checklist (must pass before P3 ships)

| AC | Criterion |
|---|---|
| AC-1 | Build green: 5/5 xcodebuild schemes (Leaf / LeafAgent / LeafMCP / LeafCore / LeafCorePrivate-stub) on author's Mac. |
| AC-2 | SPM test count ≥ (P1-baseline + 30). P3 branches OFF `feature/track-7-P1-foundation-claude-code` head `90180348`, not off P2-collapsed. Actual P1-baseline locked at Phase A by recording `swift test 2>&1 \| tail -5` count; AC-2 target = baseline + ≥30. (P2-collapsed reached 2626 in its branch but is NOT in P3's tree.) |
| AC-3 | `just check-tokens` passes — zero new hex / pt values. |
| AC-4 | Privacy walkback grep (§6.8) returns 0 hits across P3 file scope. |
| AC-5 | `WorkStatePayloadWalkbackTests` passes (Mirror-based ADR-010 fence on all 6 new payload types). |
| AC-6 | Manual A–G smoke passes on author's Mac. |
| AC-7 | 0 new event_kinds in `ShareEventTypeKey` registry. |
| AC-8 | 0 new migrations in `Packages/LeafCore/Sources/LeafCore/DB/Migrations/`. |
| AC-9 | 0 new MCP tools in `LeafMCP/Tools/`. |
| AC-10 | Independent code review (Stage 6 subagent) returns ACCEPT or ACCEPT-WITH-NITS verdict. |

### 7.3 Known waivers carried in from P2-collapsed

`Color(red:0.18,0.41,0.92)` on `ConnectionsView.swift:199` — pre-existing nit blocking `just check-tokens` strict mode. Not P3 scope; documented carry-over for orthogonal fix commit.

---

## 8. Open questions / known gaps

| Tag | Question | Resolution |
|---|---|---|
| OQ-P3-1 | `BlockerKind` / `BlockerTargetKind` permissive `.other(String)` case — needed in v1.0 or defer? | **Include from day one.** M014 `blocker_kind` and `target_kind` are free-text columns; detector evolution can emit new strings any time. `.other(String)` fallback prevents prod decoder crashes when detector vocabulary expands. Display rendering: `.other(raw)` rendered as humanized `raw` (lowercase → Title Case via `String.localizedCapitalized` or naive split-on-underscore). |
| OQ-P3-2 | `OpenQuestion.contextRef` decoded from 3 separate DB columns (`slack_thread_ts` / `linear_issue_ref` / `github_pr_ref`) — what if multiple are non-null? | **First-non-nil wins** in private prod decoder, priority `slack → linear → github`. Document in private decoder (not visible publicly). For P3 view code, `contextRef: ContextRef?` is opaque sum-type; renderer handles all 3 cases. |
| OQ-P3-3 | `WhereStoppedSnapshot.wipSignals` decoded from `wip_signals_json` — current detector emits `{signal: count}` object, but spec §9.2 returns `[String]`. | **Decode in private prod impl** by formatting `{signal: count}` pairs into `["5 files", "3 PRs", ...]` strings. Stub returns `[]`. View renders as middle-dot-joined inline. |
| OQ-P3-4 | Detail screen Recent block sorting for resolved partition — sort DESC by `resolved_at_ms` or by `opened_at_ms` of original event? | **DESC by `resolved_at_ms` per master spec §6.3.** Already locked. |
| OQ-P3-5 | Card visibility when D3 detectors are disabled (theoretical future toggle in Settings → AI Tools)? | **N/A in v1.0** — D3 always-on substrate. If future config gate appears, card hides; not a P3 concern. |

---

## 9. Carry-overs to P11

- Clickable navigation on `contextRef` inline text → Layer B drill-down (P8-collapsed) Linear / GitHub / Slack screens or external app launchers.
- Trend annotation on detail headline (Δ vs previous period for counts) — needs cross-period diffing math.
- Real-time D3 detector tick badge ("detected 2 new questions in last hour") — relies on event-bus from `DetectorScheduler` to UI (none today).
- HIG sweep pass for sub-tab transition animation polish (master spec §11).
- Persistent sub-tab + range state across pop → re-entry (defer; UserDefaults storage trivial in v1.1).
- Empty-state CTA: "What's a Decision / Blocker / Question / Where-stopped snapshot? Learn more →" link to whitepaper section. Defer until whitepaper has dedicated D3 explainer (not landed yet).

---

## 10. References

- **Master spec:** `docs/superpowers/specs/2026-05-17-track-7-ui-surface-polish-design.md` §6 (Work State card + detail), §9.1 (DerivedInsights additions), §9.2 (return types), §12 P7 (phase scope).
- **P1 template precedent:** `docs/superpowers/specs/2026-05-17-track-7-ui-surface-polish-design.md` §4 (SurfaceCard), §5 (SurfaceDetailLayout); branch `feature/track-7-P1-foundation-claude-code` head `90180348`.
- **P2-collapsed precedent (for test fence + payload pattern):** `docs/superpowers/specs/2026-05-18-track-7-P2-collapsed-capture-surfaces.md`; branch `feature/track-7-P2-collapsed-capture-surfaces` head `1cf7175e` (not in P3 baseline; reference only).
- **D3 substrate:** `Packages/LeafCore/Sources/LeafCore/DB/Migrations/M014_DetectionTables.swift` (5 tables) + `Packages/LeafCore/Sources/LeafCore/Detection/` (DetectorPipeline / DetectorMoat / DetectorScheduler) + `Packages/LeafCore/Sources/LeafCore/MCP/QueryEngine.swift` (3 structured MCP tools).
- **Substrate architecture:** `.claude/shared/architecture.md` §"Storage (M001..M014)" + §"Derived Insights Engine".
- **CLAUDE.md workflow rules:** `.claude/shared/conventions.md` "Одна phase = одна сессия" (8 stages).
