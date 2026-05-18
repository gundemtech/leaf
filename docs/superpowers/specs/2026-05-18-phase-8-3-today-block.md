# Phase 8.3 — TODAY block wire-up · Spec

**Status:** Draft (2026-05-18). Promoted to "Active" after user review gate closes.
**Track:** Track 8 — Home as Operational Console (`docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md`).
**Stage:** 3 (Spec write) of the 8-stage per-phase workflow (`.claude/shared/conventions.md`).
**Predecessors:**
- Phase 8.1 substrate (already landed on `feature/phase-8-1-substrate`): `TodayMetrics`, `SurfacePill`, `DerivedInsights.todayMetrics(now:)` protocol method + default + `ProdInsights+TodayMetrics.swift` (122 LOC) impl + 4 integration tests.
- Phase 8.2 placeholder (already merged into `feature/phase-8-1-substrate` via FF on 2026-05-18): `Leaf/Views/Window/Home/Blocks/TodayBlock.swift` shell with `LeafEmptyState` placeholder.

---

## 1. Goal & scope

Phase 8.3 replaces the `TodayBlock` placeholder body (currently a `LeafEmptyState`) with the real TODAY block per Track-8 master spec §4.1: anchor at top of Home, glanceable today snapshot (focused time / AI ratio / sessions / context switches / commits), plus a surface pill strip (top-N surfaces by event count today) that routes to existing detail screens on tap.

**Fitness function:**

1. Wire `DerivedInsights.todayMetrics(now:)` to `TodayBlock` via `InsightsReader` snapshot. No new DerivedInsights protocol additions — Phase 8.1 already shipped the method.
2. Render the 5-metric row + pill strip per master spec ASCII §3.
3. Pill click → existing `RouteCoordinator.pushHome(_ surface: HomeSurface)` (already wired in Phase 8.2 NavigationStack); requires `SurfacePill.id` ↔ `HomeSurface` mapping.
4. 5 states handled per master §4.1 + §8.2: `loaded` / `loading` (skeleton) / `empty` ("Nothing captured yet today" centered, no pills) / `error` (banner above metrics, last-known metrics still render) / `notConfigured` (same as empty — TODAY is anchor, never disappears via full-page state).
5. Token fidelity 100% — `LeafCard` + `LeafType` + `LeafColor` + `LeafChip` (existing token) + `LeafSpace`.
6. `just check-tokens` 3-tier clean, no new hard-coded hex/pt.
7. Privacy invariant: no new event_kinds / migrations / ShareEventTypeKey changes. No new captured-data fields surfaced (commit count, focus minutes, AI ratio, surface event counts — all already-allow-listed aggregates).

**In scope:**

- `TodayBlock.swift` body rewrite (placeholder → real wired UI).
- `InsightsSnapshot` extension: new `todayMetrics: TodayMetrics` field, populated by `InsightsReader.refresh()`.
- `InsightsReader.refresh()` extension: call `insights.todayMetrics(now: Date())` once during the existing parallel-fetch flow.
- `SurfacePill.id` → `HomeSurface` mapping helper (one-line resolver living in `Leaf/Models/HomeSurface.swift` or a new `SurfacePillRouter.swift`).
- `+N` overflow pill expansion behaviour: cap visible pills at 6 (UI decision; mirrors Track-7 pattern of "≤8 in DB, ≤6 visible, expand inline on tap").
- Skeleton loading state for TODAY (≥250ms always-on per master OQ-T8-3 decision).

**Out of scope (hard exclusion):**

- YOU·NOW block wire-up (P4).
- WITH YOU ON THIS wire-up (P5).
- INBOX wire-up (P6).
- WHERE STOPPED wire-up (P7).
- Activity → Analytics tab rename (P8).
- Polish / accessibility / performance sweep (P9).
- New `DerivedInsights` protocol methods — Phase 8.1 already shipped `todayMetrics(now:)`.
- New migrations / event_kinds / ShareEventTypeKey entries.
- LeafCorePrivate substrate changes — `ProdInsights+TodayMetrics.swift` already lands metrics; if its SQL needs tweaks they ship as separate hotfix patch, not P3.
- Multi-day picker / date range customization (TODAY is local-day per system clock).
- AI narrative ("describe your day in words") — v1.1 BYOK track.

---

## 2. Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| **Data flow** | `InsightsReader.snapshot.todayMetrics: TodayMetrics` populated once per `refresh()` | Mirrors existing pattern for 23 other snapshot fields. Avoids duplicate DB calls from view body. |
| **Pill ID → route mapping** | New static helper `SurfacePillRouter.surface(forPillID:)` returning `HomeSurface?` | `HomeSurface` enum lives in app target (not LeafCore); mapping cannot live inside `TodayMetrics` struct without leaking app types into LeafCore. Static helper keeps separation. |
| **Pill cap on screen** | 6 visible, `+N` overflow chip when count exceeds | Avoids horizontal scroll on Home; consistent with Track-7 truncation aesthetic. |
| **`+N` overflow behaviour** | Tap → expand inline (no modal/sheet); replaces `+N` chip with the remaining N pills | Matches master §4.1 decision ("`+N` overflow pill expands to show remaining pills inline (no modal)"). Stateful: `@State private var pillsExpanded: Bool`. |
| **Loading state** | Skeleton always for ≥250ms even if data arrives faster (master OQ-T8-3) | No flash of empty → loaded. Use `Task.sleep(for: .milliseconds(250))` race against real fetch, surface whichever resolves last. |
| **Empty state** | "Nothing captured yet today" centered subtitle in same `LeafCard`; no pills row; metrics replaced by `—` placeholders OR collapsed entirely | Picked the second — collapsed metrics row, just the subtitle. `LeafEmptyState` inside `LeafCard` (consistent with Phase 8.2 placeholder pattern). |
| **Error state** | `LeafBanner.danger` placed ABOVE the metrics card (not inside), card still renders with last-known values | Master §4.1 calls it out: "banner above metrics, metrics still render last-known". `InsightsReader` already retains last successful snapshot through `.error(msg)` state. |
| **`notConfigured` state** | Same as `empty` — TODAY is anchor, never full-page | Master §4.1 decision. Diverges from sibling top-level state machine. |
| **Pill click target** | `coordinator.pushHome(surface)` — same path Track-7 surface cards used | NavigationStack destinations preserved in P2 — already resolvable for HomeSurface. |
| **5-metric row layout** | Horizontal `HStack` with `LeafSpace.lg` between metrics, each metric = `VStack(value: LeafType.title.medium, label: LeafType.body.small)` | Matches Track-7 `LeafMetricAmbient` pattern; consistent typography. |
| **AI ratio formatting** | `"\(Int((aiRatio * 100).rounded()))%"` | Mirrors existing `TodaySection.inlineMetricFragments` (pre-rewrite HomeView). |
| **Focus formatting** | Hours + minutes if ≥ 60min (`"3h 24m"`), minutes only if < 60min (`"42m"`), `"—"` if 0 | Mirrors existing `formatDuration` helper from pre-rewrite HomeView. |
| **Pill ID source** | `SurfacePill.id == HomeSurface.rawValue` for every `HomeSurface` case + `linear`/`github`/`slack` for Layer B surfaces | `ProdInsights+TodayMetrics.swift` already iterates `HomeSurface.allCases` per Phase 8.1 spec — pill IDs are stable. Linear/GitHub/Slack pills route via `pushHomeLayerBProvider`, not `pushHome`. |
| **Layer B pill routing** | Layer B pills (`linear`/`github`/`slack`) route via `pushHomeLayerBProvider(_:)`; capture-surface pills (`claude_code`/`xcode`/`ides`/`browsers`/`zoom`/`calendar`) via `pushHome(_:)` | Two-route dispatch in `SurfacePillRouter`; preserves existing nav-graph semantics. |

---

## 3. Data flow

### 3.1 Existing (Phase 8.1)

```
ProdInsights+TodayMetrics.swift
  → todayMetrics(now: Date) throws -> TodayMetrics
    → SQL aggregation across events table for today window
    → returns TodayMetrics(focusedMin, aiRatio, sessionsCount, switchCount, commitsCount, surfacePills)
```

### 3.2 New (Phase 8.3)

```
InsightsReader.refresh() — Leaf/Models/InsightsReader.swift
  → ... existing 23 fetches ...
  → 24th fetch: let todayMetrics = try insights.todayMetrics(now: now)
  → Snapshot(todayMetrics: todayMetrics, ...)
  → State.loaded(snapshot)

HomeView body — switch reader.state
  case .loaded(let snapshot, _):
    HomeContent(snapshot: snapshot)        // changed from HomeContent() in P2

HomeContent — Leaf/Views/Window/Home/HomeView.swift
  → TodayBlock(metrics: snapshot.todayMetrics)
  → ... 4 other blocks unchanged ...

TodayBlock — Leaf/Views/Window/Home/Blocks/TodayBlock.swift
  let metrics: TodayMetrics      // accept metrics; no @Environment
  body:
    VStack {
      Text("TODAY · \(weekdayDateFormat(Date()))").leafSectionLabel()
      LeafCard {
        if metrics == .empty { emptyState }
        else                  { metricsRow + pillStripIfPresent }
      }
    }
```

`HomeContent` regaining the snapshot parameter is the smallest backward-compatible change to land the wire-up; P4-P7 each add their respective metric field to the snapshot + wire their block analogously.

### 3.3 Skeleton/loading discipline

`InsightsReader` exposes `.loading` as a top-level state — Home renders `LoadingScaffold` (already there from P2). Phase 8.3 does NOT add a per-block skeleton — top-level scaffold suffices. Master OQ-T8-3 "skeleton always for ≥250ms before flash" is satisfied implicitly via `InsightsReader.refresh()` minimum delay (already present from Track-2 D2).

---

## 4. New / modified types

### 4.1 `InsightsSnapshot` — add field

`Leaf/Models/InsightsSnapshot.swift` (or wherever the struct lives — Discovery in new session confirms):

```swift
struct InsightsSnapshot {
    // ... existing 23 fields ...
    let todayMetrics: TodayMetrics       // NEW — Phase 8.3
}
```

All call sites that construct `InsightsSnapshot` must pass the new field. Compiler enforces.

### 4.2 `InsightsReader.refresh()` — wire fetch

Add one call inside the existing parallel-fetch flow (or sequential if reader is sequential — confirm in Discovery):

```swift
let todayMetrics = try insights.todayMetrics(now: now)
```

Inject into the new snapshot constructor.

### 4.3 `SurfacePillRouter.swift` — new helper

`Leaf/Models/SurfacePillRouter.swift`:

```swift
import LeafCore

enum SurfacePillRouter {
    /// Returns the navigation route for a TODAY pill, or nil if the pill ID
    /// is not a known surface. nil callers leave the pill non-tappable.
    static func route(forPillID id: String) -> SurfacePillRoute? {
        if let surface = HomeSurface(rawValue: id) {
            return .homeSurface(surface)
        }
        if let provider = LayerBProvider(rawValue: id) {
            return .layerBProvider(provider)
        }
        return nil
    }
}

enum SurfacePillRoute: Equatable {
    case homeSurface(HomeSurface)
    case layerBProvider(LayerBProvider)
}
```

The view consumes the route enum and calls the matching `RouteCoordinator` push method.

### 4.4 `TodayBlock.swift` — rewrite body

Full body replacement. ~110 LOC target. See plan §Task 5 for the canonical content.

---

## 5. Layout (per master §3 + §4.1)

```
┌─ TODAY · Mon 18 May ─────────────────────────────────┐
│                                                       │
│  3h 24m      68%        4         12        2         │
│  focused     AI ratio   sessions  switches  commits   │
│                                                       │
│  ─────────────────────────────────────────────        │
│                                                       │
│  [Claude 14] [Xcode 8] [Linear 3] [Slack 5] [+2]      │
│                                                       │
└───────────────────────────────────────────────────────┘
```

- 5 metrics in single `HStack`, equal-spaced
- `LeafDivider()` between metrics row and pill strip
- Pill strip = `LazyHStack` (or plain `HStack` with `ScrollView(.horizontal)` if dynamic count) of `LeafChip` per pill, with `+N` overflow chip when total > 6
- `+N` chip toggles `pillsExpanded` state — expanded shows all pills, collapsed shows top 6 + `+N`

---

## 6. State machine (per-block)

| State source | Trigger | Render |
|---|---|---|
| `metrics == .empty` (from `TodayMetrics.empty` static — Phase 8.1) | Cold boot / no events captured today | "Nothing captured yet today" centered subtitle; no metrics row; no pills |
| `metrics != .empty`, all numeric fields 0 except `surfacePills.isEmpty == false` | Pills present without focused time (edge: events captured but no focus sessions yet) | Metrics row with `—` placeholders + pill strip |
| `metrics != .empty`, full data | Loaded happy path | Metrics row + pill strip per §5 |

Top-level `InsightsReader.State` cases (`loading` / `notConfigured` / `error`) are owned by `HomeView` — `TodayBlock` only sees the `metrics` value from a `.loaded` snapshot. If `notConfigured`, `HomeView` renders full-page state and `TodayBlock` doesn't render. (Master §8.1.)

---

## 7. Privacy walkback audit

No new captured-data fields surfaced. All `TodayMetrics` fields are aggregates:

- `focusedMin: Int` — sum of focus session durations (already aggregated)
- `aiRatio: Double` — 0…1 percentage
- `sessionsCount: Int` — count
- `switchCount: Int` — count × duration
- `commitsCount: Int` — count
- `surfacePills: [SurfacePill]` — each `(id: String, label: String, count: Int)` — surface identifier + count, no titles/paths/identifiers from underlying events

Privacy walkback grep (run during P9 acceptance): `grep -nE 'absolute_path|full_comment_body|raw_email|notes_body' Leaf/Views/Window/Home/Blocks/TodayBlock.swift` → 0 hits expected.

---

## 8. Test plan

P3 is UI-shell + light wire-up. Tests are mostly compositional (do existing tests still pass after `InsightsSnapshot` extension?) plus one focused matcher test for `SurfacePillRouter`.

### 8.1 New tests (LeafCorePrivateTests / LeafTests as appropriate)

**`SurfacePillRouterTests.swift`** — 4 cases (LeafTests target if it exists; otherwise inline in Leaf scheme test target):

1. Known capture surface `"xcode"` → `.homeSurface(.xcode)`
2. Known Layer B `"linear"` → `.layerBProvider(.linear)`
3. Unknown ID `"fortnite"` → `nil`
4. Empty string `""` → `nil`

### 8.2 Regression coverage

`InsightsSnapshot` adds one required field. All existing snapshot-builder call sites must compile + tests pass. No new tests for the wiring itself — `ProdInsights+TodayMetrics` is already covered by 4 integration tests from Phase 8.1.

### 8.3 Manual smoke (P3 acceptance)

| ID | Description | Expected |
|---|---|---|
| MS-1 | Open Home on a workspace with active session in Xcode + 3 git commits today | TODAY card renders with focused time > 0, sessions ≥ 1, commits = 3, ≥ 1 surface pill (e.g. `Xcode N`) |
| MS-2 | Click `Xcode N` pill | Navigates to `XcodeDetailScreen` |
| MS-3 | Click `Linear M` pill | Navigates to `LinearDetailScreen` (via `pushHomeLayerBProvider`) |
| MS-4 | Cold boot (no events today, fresh DB) | TODAY card shows "Nothing captured yet today" — no pills row, no metrics row |
| MS-5 | Force `InsightsReader.State.error` (kill DB connection mid-refresh) | `LeafBanner.danger` above metrics, last-known TODAY values still render |
| MS-6 | With 8+ active surfaces today | TODAY pill strip shows 6 pills + `+N` chip; tapping `+N` reveals all pills inline (no modal) |

---

## 9. Commit decomposition (~6 atomic commits)

Estimate ~6 atomic commits on `feature/phase-8-3-today-block` (off `feature/phase-8-1-substrate`):

1. `feat(phase-8-3): SurfacePillRouter helper + tests` — new file `Leaf/Models/SurfacePillRouter.swift` + 4 tests
2. `feat(phase-8-3): InsightsSnapshot.todayMetrics field + reader wiring` — modify `InsightsSnapshot` struct + `InsightsReader.refresh()` call; update all snapshot construction sites
3. `feat(phase-8-3): HomeView pass snapshot into HomeContent` — re-introduce `snapshot` param in `HomeContent` (P2 dropped it for shell phase); wire to `TodayBlock(metrics:)`
4. `feat(phase-8-3): TodayBlock metrics row + pill strip wire-up` — replace placeholder body with real composition
5. `feat(phase-8-3): TodayBlock +N overflow expand behaviour` — `@State pillsExpanded` + conditional render
6. `chore(phase-8-3): wrap + token sweep` — `just check-tokens` clean, `just check-style` if any LineLength violations introduced

---

## 10. Risks & open items

| ID | Concern | Mitigation |
|---|---|---|
| R-1 | `SurfacePill.id` from Phase 8.1 may use different naming than `HomeSurface.rawValue` (e.g. `"claude_code"` vs `"claudeCode"`) | Plan Task 1 includes a verification step: read `ProdInsights+TodayMetrics.swift` to confirm exact pill ID strings before writing `SurfacePillRouter` mapping |
| R-2 | `InsightsSnapshot` extension breaks all snapshot construction call sites (tests + previews) | Plan Task 2 includes a grep sweep + update of all sites; tests must compile before moving on |
| R-3 | LayerBProvider rawValue may not match `surfacePill.id` for Linear/GitHub/Slack (Phase 8.1 emits `surfaceKey` not provider key) | Plan Task 1 verifies via reading the ProdInsights file; if mismatch, add normalization in `SurfacePillRouter` |
| R-4 | TODAY metrics row at narrow window width (≤ 600pt) may wrap or clip | Use `ViewThatFits` to fall back to a 2-row compact layout, OR defer to P9 polish — decided at P3 implementation time based on real render |
| R-5 | Pill `+N` overflow when count exceeds visible cap — animation jank when expanding | Standard SwiftUI `.animation(.default, value: pillsExpanded)` on the `HStack`; verify on device in P3 manual smoke |
| OQ-P3-1 | Should pill counts show `0` pills when 0 surfaces today? | No — empty `surfacePills` → no pill strip rendered at all. Decided. |
| OQ-P3-2 | TODAY section label format: `"TODAY"` vs `"TODAY · Mon 18 May"` | Master §3 ASCII shows `"TODAY · Mon 18 May"`. Use `DateFormatter` with locale `.current`, format `"EEE d MMM"`. |
| OQ-P3-3 | If commits today = 0 AND surface pills have no `git_commit`-bearing surfaces, do we still render the commits cell? | Yes — render with `0` value. Cells are stable; 0 is data, not absence. |

---

## 11. Files touched

**New:**
- `Leaf/Models/SurfacePillRouter.swift`
- `Leaf/Tests/SurfacePillRouterTests.swift` (or wherever Leaf-target tests live — Discovery confirms)

**Modified:**
- `Leaf/Models/InsightsSnapshot.swift` — add `todayMetrics: TodayMetrics` field
- `Leaf/Models/InsightsReader.swift` — call `insights.todayMetrics(now:)` in `refresh()`; pass to snapshot init
- `Leaf/Views/Window/Home/HomeView.swift` — re-introduce `snapshot` param in `HomeContent` body; wire `TodayBlock(metrics:)`
- `Leaf/Views/Window/Home/Blocks/TodayBlock.swift` — body rewrite (placeholder → real metrics + pills)
- All other call sites of `InsightsSnapshot(...)` initializer (likely test fixtures + previews) — pass `todayMetrics: .empty` if no explicit data needed

**Deleted:** none.

---

## 12. Acceptance criteria (this phase)

| AC | Description | Evidence |
|---|---|---|
| AC-1 | `TodayBlock.swift` renders 5 metrics (focused / aiRatio / sessions / switches / commits) + pill strip when data present | code inspection + MS-1 smoke |
| AC-2 | Empty state ("Nothing captured yet today") when `TodayMetrics.empty` | MS-4 smoke |
| AC-3 | Surface pill click navigates to corresponding detail screen via `pushHome(_:)` | MS-2 smoke |
| AC-4 | Layer B pill click navigates via `pushHomeLayerBProvider(_:)` | MS-3 smoke |
| AC-5 | `SurfacePillRouter` returns correct routes for known IDs and `nil` for unknown | SurfacePillRouterTests 4 cases |
| AC-6 | All 5 xcodebuild schemes Debug build SUCCESS | manual xcodebuild per scheme |
| AC-7 | `swift test` passes — new tests added (SurfacePillRouter); existing tests still green after snapshot extension | `swift test` from repo root |
| AC-8 | `just check-tokens` 3-tier clean | `just check-tokens` |
| AC-9 | `just check-style` clean for new + modified files (no new violations) | `just check-style` |
| AC-10 | No new event_kinds / migrations / ShareEventTypeKey delta | grep verification |
| AC-11 | `+N` overflow expand behaviour works without modal | MS-6 smoke |
| AC-12 | Privacy walkback grep on new TodayBlock + SurfacePillRouter — 0 hits | manual grep |

---

## 12.5 Carry-forward to P9 (post-landing addendum, 2026-05-18)

Items recognised during P3 wrap that fit P9 polish sweep rather than P3 scope. Source: Phase 8.3 review + post-landing UX iteration with user (raw event-count pills "Claude Code 2432" rendered as meaningless badge → temporary fix in commit `4c694287` drops the count, shows surface name only). Tracked in master Track-8 spec §9.1 as C-1..C-4. Summary here for phase audit trail:

- **C-1 Hybrid surface pills + Phase 8.1 emission gap** — current pill render shows surface name only (no quantity); proper polish requires substrate shape change: capture-surfaces → attention-time (`Claude Code · 1h 47m`), Layer B → action-noun count (`Linear · 3 issues` / `GitHub · 5 commits` / `Slack · 12 msgs`). Substrate work in LeafCorePrivate: ~3 new SQL queries + extend `SurfacePill` shape (`displayValue: String` vs `kind` enum — brainstorm at P9). Also closes Phase 8.1 emission gap (Layer B providers currently never emitted as pills; router branch is dead code).
- **C-2 `.error`-state last-known retention** — spec §6 + MS-5 incorrectly assumed `InsightsReader.State.error` retains the last successful snapshot. It doesn't; refactor in P9.
- **C-3 Narrow-window `ViewThatFits` fallback** — R-4 from §10.
- **C-4 `DateFormatter` static caching** — micro-perf nit from review.

P3 closes as APPROVE-WITH-NITS with these explicitly deferred; P9 audit will close or re-defer to v1.1.

---

## 13. References

- Master Track 8 spec: `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` §4.1 + §6 + §9 P3 row
- Phase 8.1 substrate spec: `docs/superpowers/specs/2026-05-18-phase-8-1-substrate.md`
- Phase 8.2 placeholder plan: `.claude/plans/phase-8-2.md`
- Existing `LeafChip` token: confirmed present in Track-2 D1 (used by Track-7 SurfaceCard sub-stats)
- Existing `LeafDivider`: used by pre-rewrite `TodaySection` in HomeView
- `RouteCoordinator.pushHome` + `pushHomeLayerBProvider`: `Leaf/Models/RouteCoordinator.swift`
- `HomeSurface` enum: `Leaf/Models/HomeSurface.swift` (Track-7 P1)
- `LayerBProvider` enum: `Leaf/Models/LayerBProvider.swift` (Track-7 P4)
- `TodayMetrics` + `SurfacePill` types: `Packages/LeafCore/Sources/LeafCore/Insights/TodayMetrics.swift` (Phase 8.1)
- `ProdInsights+TodayMetrics.swift` impl: `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+TodayMetrics.swift`
