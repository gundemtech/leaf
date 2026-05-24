# Track-9 T9 — Analytics UI surface (Mid-tier MVP)

**Status:** SPEC — Stage 3 writing.
**Track-9 master design:** [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md) §3.5 + §T9 (lines 215-220).
**T4 spec (substrate consumed):** [`2026-05-20-track-9-T4-weekly-metrics-deriver.md`](./2026-05-20-track-9-T4-weekly-metrics-deriver.md) — `WeeklyMetrics` + `DailyMetric` shape, `.empty` static, `DerivedInsights.weeklyMetrics(now:)` API.
**T7 spec (parity precedent — defaulted-init snapshot wiring):** [`2026-05-21-track-9-T7-where-stopped-4line.md`](./2026-05-21-track-9-T7-where-stopped-4line.md) §3.3 Path B composition pattern.
**T8 spec (parity precedent — Track-9 phase verification gates):** [`2026-05-21-track-9-T8-inbox-feeder-expansion.md`](./2026-05-21-track-9-T8-inbox-feeder-expansion.md) §6 (AC gates 10/10).
**Branch:** `feature/track-9-substrate` (off T8 SHIPPED tip `470cc0da`). FF после T9 acceptance.
**Ship classification:** Pure UI ship — zero substrate touches. Substrate-purity invariant T1-T8 streak preserved at 9 phases. Master spec §9.1 carry **C-23 RESOLVED T9**.

---

## 1. Scope

**In scope:**

1. **`AnalyticsView.swift` full rewrite** — replace Phase 8.8 40-LOC placeholder с real surface. State machine wrapper reading `InsightsReader.State` (mirror `HomeView` Track-8 P3 pattern + Track-9 T6 last-known retention). Branches: `.loading` ProgressView + "Reading weekly metrics…", `.loaded(snapshot, _)` → `AnalyticsContent(metrics: snapshot.weeklyMetrics)`, `.error(msg, lastKnown)` → error banner + `AnalyticsContent(metrics: lastKnown?.weeklyMetrics ?? .empty)`, `.notConfigured(msg)` + `.empty(msg)` → full-page LeafEmptyState placeholders parity с HomeView.
2. **`AnalyticsContent.swift`** new view — receives `metrics: WeeklyMetrics` (NOT full snapshot, single-purpose) + composes 6 child blocks. Branches `.empty == metrics` Equatable check → single LeafCard с LeafEmptyState ("Not enough data yet — keep working and check back tomorrow"); else populated layout per spec §3.
3. **6 new child block views** в `Leaf/Views/Window/Analytics/Blocks/` (separate files, mirror Home/ structure):
   - `WeekChipStrip.swift` — 7 horizontal chips from `dailySeries`, today highlighted с `accent.primary` tone.
   - `DailyFocusedChart.swift` — SwiftUI Charts: `BarMark` focused-min primary Y + `LineMark` aiRatio secondary Y (dual-axis). First Charts usage in codebase.
   - `StreaksCard.swift` — 5 streak rows в single LeafCard, SF Symbol icon + label + count per row.
   - `PeakHourCallout.swift` — 24-dot strip + peak hour highlighted (single peak only — no fake density grading).
   - `WoWDeltaCallout.swift` — sparkline (7-point LineMark from `dailySeries.focusedMin`) + delta text (+/- prefixed percent или "—" if nil).
   - `TopToolsPlaceholder.swift` — honest "Coming soon" card (substrate gap from T4 D-1 deviation, T6 owns SurfacePill discriminator).
4. **`InsightsSnapshot.weeklyMetrics: WeeklyMetrics = .empty`** defaulted field added to both `InsightsSnapshot` init signatures (compact + convenience). Existing 23 fixture callsites preserved (defaulted-init discipline 6-я итерация: T3 todayMetrics / T4 youNowState / T5 sameTaskTeammates / T6 inboxItems / T7 whereStopped + T9 weeklyMetrics).
5. **`InsightsReader.refresh()`** insertion — 23rd sequential SQL call `try insights.weeklyMetrics(now: Date())` between `recentLastCommit` fetch (line 200) и whereStopped composition (line 205). Threaded into `InsightsSnapshot(...)` init (line 259) as `weeklyMetrics: weeklyMetrics`.
6. **State machine routing** — `RootView.detail(for: .analytics)` switch case (line 65) unchanged — instantiates new `AnalyticsView()` which reads `@Environment(InsightsReader.self)` directly (parity HomeView line 28).
7. **Animation** — `.easeInOut(duration: 0.25)` cross-fade на `value: metrics` для `.empty ↔ populated` transitions (parity P3/P4/P5/P6/P7 precedent). SwiftUI Charts API auto-animates BarMark/LineMark on data change.
8. **A11y** — basic `accessibilityLabel` + `accessibilityHint` per child block (P9 sweep pattern from Track-8 P9). No per-bar a11y in chart (Charts default rotor sufficient).

**Hard exclusion (out of T9 — carry list):**

- **`topToolsWeek: [SurfacePill]` substrate field** — T4 D-1 deviation explicitly dropped, T6 owns SurfacePill discriminator refactor. T9 ships `TopToolsPlaceholder` honest "Coming soon" card; substrate addition + real `TopToolsCard` carry to post-Track-9 phase (master spec §9.3 amendment T10 wrap).
- **Per-day chart drill-down (tap on bar → detail screen)** — YAGNI, no `pushAnalytics*` `RouteCoordinator` methods, no new `AppRoute` cases. Static charts ship.
- **Multi-week / 30-day / 90-day variant** — T4 D-2 locked single 7-day period. Future expansion via parallel `metrics(period:)` API.
- **`get_weekly_metrics` MCP tool** — post-Track-9 if AI clients request.
- **Localization** — labels hardcoded English per Track-8 P9 carry C-19. Separate localization track.
- **`recentActivity` orphan drop** — Track-8 P9 carry C-24, owned by T10 wrap. T9 OUT OF SCOPE.
- **8-day chip variant** — T4 D-8 explicitly locked 7-day window. Master spec §T9 "8 day chips" wording is imprecise; T10 wrap may amend.
- **Per-hour distribution heatmap** — substrate gap. T9 renders single peak via 24-dot strip; future enrichment to per-hour bucket distribution is post-Track-9 substrate phase if user demand emerges.
- **Activity tab section name** — already "Analytics" post-Phase 8.8 P8 rename. T9 only swaps content of `AnalyticsView`.
- **`AnalyticsContent` consuming full snapshot** — accepts only `metrics: WeeklyMetrics` (single-purpose). Future Analytics expansion (monthly / per-source) needs separate phase contracts.

### 1.1 Deviations from Track-9 master spec §T9

Master spec line 218:
> `InsightsReader` extension fetches `weeklyMetrics(now:)` in `refresh()` → `InsightsSnapshot.weeklyMetrics: WeeklyMetrics?` defaulted Optional field.

**T9 implements defaulted `WeeklyMetrics = .empty` (not Optional).**

Rationale: T4 substrate ships first-class `WeeklyMetrics.empty` static (mirror P3 `TodayMetrics.empty` + P4 `YouNowState.empty` precedent). Optional layer would be redundant — `.empty` already encodes "no data yet" semantic, callsites read `metrics == .empty` Equatable check (auto-synthesized). Master spec wording outdated (written pre-T4 ship). Carry: master spec §T9 line 218 amendment in T10 wrap.

Master spec line 217:
> Components: `WeekChipStrip` (8 day chips) + `DailyFocusedChart` (SwiftUI Charts) + `StreaksCard` (5 streaks) + `PeakHourCallout` (24h mini-heatmap) + `TopToolsCard` (week-scoped pills) + `WoWDeltaCallout` (sparkline).

**T9 implements 7 chips + TopToolsPlaceholder honest "coming soon" card.**

7 vs 8 — T4 D-8 substrate locks 7-day window. Master spec "8" was UI artifact wording (today partial + 7 prior). T9 mirrors substrate.

TopToolsCard → Placeholder — T4 D-1 explicitly dropped `topToolsWeek` substrate field (T6 owns SurfacePill discriminator). T9 ships honest placeholder per user choice during Stage 2 brainstorm (Q2 — "Render 'Coming soon' placeholder card" option selected). Better UX than skipping entirely (preserves master spec §3.5 6-component shape commitment), worse than empty silence (small acknowledged scaffold).

Master spec line 217 "PeakHourCallout (24h mini-heatmap)":

**T9 renders 24-dot strip with single peak highlighted (not graded heatmap).**

Substrate ships only `peakHour: Int?` (single bucket), not per-hour distribution. Heatmap requires distribution data. T9 strip honestly shows "this hour was the peak across the week" without fabricating density grading (which would imply visualised data we don't have).

Net deltas updated:
- ShareEventTypeKey registry +**0** (no new event_kinds — registry frozen at 198 post-T3).
- SQLCipher migrations +**0** (no DDL).
- MCP tools +**0**.
- `InsightsSnapshot` field shape: defaulted `.empty`, not Optional.
- 6 components shipped (1 honest placeholder).

Master spec §T9 amendment owned by T10 wrap.

**Additional deviations discovered during Stage 6 independent review:**

**(5) `DailyFocusedChart` ships single-Y-axis с `aiRatio × 100` rendering trick (NOT true dual-axis per Q-5).** macOS 14 SwiftUI Charts API does not natively support dual-Y-axis (`chartYAxis` accepts single axis configuration); real dual-axis requires custom `ChartContent` work или macOS 15+ API features. Author shipped single-axis с aiRatio percent rendering against the same focused-min auto-scale + legend label "AI ratio (%)" clarifying the convention. Visual compression of aiRatio LineMark on weeks with ≥200 focused-min/day is acknowledged — trend slope still readable, peak position visible. **Carry C-44 (post-Track-9 polish):** real dual-axis с separate Y scales once macOS 15+ baseline lands, или custom `Chart.chartOverlay { ... GeometryReader ... }` approach if pre-baseline. Q-5 amendment T10 wrap.

**(6) `AnalyticsContent` empty-state branch uses `isLogicallyEmpty` predicate (NOT raw `metrics == .empty` Equatable check per Q-8).** Substrate behavior: `ProdInsights.weeklyMetrics(now:)` always populates `dailySeries[*].dayStartMs` with real local-TZ midnight timestamps for the past 7 days, even on a fresh cold DB. `WeeklyMetrics.empty` static carries `dayStartMs = 0` placeholders. Resulting prod-shipped snapshot fails Equatable check against `.empty`, so the friendly "Not enough data yet" empty-state would never fire on real users. Fix: `AnalyticsContent.isLogicallyEmpty` computed predicate checks `dailySeries.allSatisfy { $0.focusedMin == 0 && ... }` AND all streaks zero AND `peakHour == nil` AND `wowDelta == nil`. UX semantic preserved; substrate semantic unchanged. Q-8 amendment T10 wrap.

---

## 2. Decisions taken (Stage 2 brainstorm output)

| # | Question | Decision | Rationale |
|---|---|---|---|
| Q-1 | `InsightsSnapshot.weeklyMetrics` field shape | **Defaulted `WeeklyMetrics = .empty`** (NOT Optional). | Master spec line 218 outdated. T4 substrate ships `.empty` first-class — mirror P3 `TodayMetrics`/P4 `YouNowState` precedent. Optional adds redundant layer. `.empty == metrics` Equatable check for empty-state branch. Existing 23 fixture callsites preserved via defaulted-init. |
| Q-2 | TopToolsCard fate (substrate gap) | **Render "Coming soon" placeholder card** (honest stub). | T4 D-1 dropped `topToolsWeek` substrate field (T6 SurfacePill coupling). User chose Q2 Option C during brainstorm — preserves 6-component master spec §3.5 shape commitment. Better UX than skip (acknowledges placeholder), better than full TopToolsCard (substrate doesn't exist). T6 ownership; real card lands when substrate ships (carry post-Track-9). |
| Q-3 | PeakHourCallout viz (substrate gap) | **24-dot strip + single peak highlighted**. | Substrate ships only `peakHour: Int?`, no per-hour distribution. 24-dot strip visualizes peak position на 24h timeline без fabricating density grading. Honest minimal visualization. SVG-free, pure SwiftUI shapes. |
| Q-4 | Component composition | **AnalyticsContent + 6 child block files** (mirror HomeContent / TodayBlock / YouNowBlock paradigm). | HomeContent precedent. Per-block testability. File LOC budgets respected. Separate files per block в `Leaf/Views/Window/Analytics/Blocks/`. |
| Q-5 | DailyFocusedChart shape | **BarMark + LineMark dual-axis** (per master spec contract). | First Charts usage in codebase. Primary Y: focused-min as BarMark `LeafColor.accent.primary`. Secondary Y: aiRatio 0..1 as LineMark + PointMark `LeafColor.status.info`. Auto-animates on data change (Charts API native). |
| Q-6 | Layout flow | **Hero → secondary HStack → callouts** (vertical ScrollView). | Header → WeekChipStrip → DailyFocusedChart (hero ~240pt height) → HStack { StreaksCard + PeakHourCallout } → WoWDeltaCallout (full-width) → TopToolsPlaceholder (small footer). Establishes visual hierarchy: chart-first, details below. |
| Q-7 | Chart interactivity (tap → drill-down) | **Static charts, no tap/drill-down**. | YAGNI. No `RouteCoordinator.pushAnalytics*` methods. No new `AppRoute` cases. Tap interactivity post-Track-9 if user demand emerges. |
| Q-8 | Empty state UX distinguishability | **`metrics == .empty` Equatable check** → single full-card LeafEmptyState ("Not enough data yet — keep working and check back tomorrow"). | `.empty` substrate-provided sentinel. No need to distinguish cold-DB vs genuinely-zero-week — both render same message. WeeklyMetrics `Equatable` auto-synth ships T4. |
| Q-9 | WeekChipStrip chip count | **7 chips = `dailySeries`** 1-to-1 (NOT 8). | Substrate fidelity. Today = `dailySeries[6]` (partial focusedMin counting up to `now`). Master spec "8" amendment T10. |
| Q-10 | Chart Y-axis range / scale | **focusedMin: 0..max(dailySeries.focusedMin) × 1.15** (15% headroom). **aiRatio: 0..1.0** fixed. | Auto-scaling for focused-min (cold-week max = 0 → degenerate; chart auto-handles). aiRatio fixed 0..1 — semantic range. |
| Q-11 | WoWDelta formatting | **`String(format: "%+d%%", round(wowDelta * 100))`** для populated; **"—"** для nil. | `+12%` / `-8%` / `0%` standard format. nil-graceful single dash. |
| Q-12 | Sparkline source data | **`dailySeries.map { $0.focusedMin }`** (7 points). | Same series as DailyFocusedChart bars (different visualization). LineMark only, no PointMark — sparkline is compact. |
| Q-13 | Streak SF Symbol mapping | `commitStreak` → `chevron.left.forwardslash.chevron.right`; `issueCloseStreak` → `checkmark.circle.fill`; `huddleStreak` → `bubble.left.and.bubble.right.fill`; `focusSessionStreak` → `target`; `heavyPulseStreak` → `flame.fill`. | Conventional SF Symbols matching streak semantics. Future polish iterations OK. |
| Q-14 | Animation | **`.easeInOut(duration: 0.25)` on `value: metrics`** (Equatable). Charts API auto-animates internal marks. | Parity P3/P4/P5/P6/P7 precedent. WeeklyMetrics Hashable/Equatable auto-synth holds. |
| Q-15 | A11y | **Per-block `accessibilityElement(children:.combine)` + `accessibilityLabel`** composing visible text. No per-bar a11y in chart — Charts default rotor sufficient. | P9 sweep pattern. Minimal — block-level only. |
| Q-16 | Tests strategy | **3 public LeafCoreTests** (InsightsSnapshot defaulted-init roundtrip + Equatable verify + .empty propagation) + **5-6 view-init tests** (block primitives accept their data shape, render without crash; minimal coverage matching codebase precedent). **No sentinel-injection** — T9 reads aggregate metrics only, не body fields (pattern parity P3/P4/P5/P7 — exempted per Track-9 master spec §6 line 285). | Codebase precedent: view tests sparse, substrate tests thorough. T9 substrate already verified в T4 (13 net new tests). T9 ship verifies UI consumer pattern. |
| Q-17 | Token discipline for Charts | **Wrap all Charts color/style API calls в Leaf tokens** (`.foregroundStyle(LeafColor.accent.primary)`, `.font(LeafType.label)`). No raw `Color.blue` / `.font(.system(...))` inside Charts blocks. | `check-tokens` MIGRATION tier covers `Leaf/Views/` including new `Analytics/Blocks/`. Tier 1+2+3 clean. |
| Q-18 | Refresh trigger | **Existing `InsightsReader.refresh()` flow** — `AnalyticsView.onAppear { reader.refresh() }` mirror HomeView line 91. | Same reader instance, same refresh cadence. Single source of truth. |
| Q-19 | Branch off | **`feature/track-9-substrate` at T8 wrap tip `470cc0da`**. FF after T9 acceptance per `current-state.md` workflow. | Parallel: also merged into `fix/dev-launch-reliability` after ship via T8 proven workflow (для dev smoke). |

---

## 3. Architecture

### 3.1 Component map

```
Leaf/Views/Window/Analytics/
├── AnalyticsView.swift                       (REWRITE — was 40-LOC placeholder)
│   ├── @Environment(InsightsReader.self) reader
│   ├── @Environment(WindowState.self) windowState
│   ├── body: state-machine switch + .onAppear refresh trigger
│   └── ~80-100 LOC budget (≤120 cap)
│
├── AnalyticsContent.swift                    (NEW — single-purpose consumer)
│   ├── struct AnalyticsContent: View
│   ├── let metrics: WeeklyMetrics
│   ├── body: VStack { WeekChipStrip → DailyFocusedChart → HStack{Streaks,Peak} → WoWDelta → TopTools }
│   ├── branch: metrics == .empty → LeafEmptyState
│   └── ~80 LOC budget (≤120 cap)
│
└── Blocks/
    ├── WeekChipStrip.swift                   (NEW)
    │   ├── struct WeekChipStrip: View
    │   ├── let days: [DailyMetric]           (7 entries oldest→newest)
    │   ├── body: HStack { ForEach(days) → chip(day:) }
    │   ├── chip(day:) — VStack { dayLabel + minLabel }, today highlighted
    │   └── ~60 LOC budget (≤80 cap)
    │
    ├── DailyFocusedChart.swift               (NEW — first Charts usage)
    │   ├── import Charts
    │   ├── struct DailyFocusedChart: View
    │   ├── let days: [DailyMetric]
    │   ├── body: Chart(days) { BarMark + LineMark + PointMark }
    │   ├── chartXAxis + chartYAxis configuration (dual-axis)
    │   └── ~100 LOC budget (≤140 cap)
    │
    ├── StreaksCard.swift                     (NEW)
    │   ├── struct StreaksCard: View
    │   ├── let metrics: WeeklyMetrics
    │   ├── body: LeafCard { VStack { streakRow × 5 } }
    │   ├── streakRow(icon: String, label: String, count: Int)
    │   └── ~80 LOC budget (≤100 cap)
    │
    ├── PeakHourCallout.swift                 (NEW)
    │   ├── struct PeakHourCallout: View
    │   ├── let peakHour: Int?
    │   ├── body: LeafCard { VStack { "Peak hour" + dotStrip + "HH:00" } }
    │   ├── dotStrip — HStack of 24 RoundedRectangle 4×4, peak index accent
    │   ├── nil-handling: "—" text + muted strip (all dots `.text.tertiary`)
    │   └── ~70 LOC budget (≤90 cap)
    │
    ├── WoWDeltaCallout.swift                 (NEW)
    │   ├── struct WoWDeltaCallout: View
    │   ├── let delta: Double?
    │   ├── let dailySeries: [DailyMetric]
    │   ├── body: LeafCard { HStack { sparkline + VStack{delta + label} } }
    │   ├── sparkline — Chart(dailySeries) { LineMark }
    │   ├── deltaText — formatted percent or "—"
    │   └── ~80 LOC budget (≤100 cap)
    │
    └── TopToolsPlaceholder.swift             (NEW — honest stub)
        ├── struct TopToolsPlaceholder: View
        ├── body: LeafCard { LeafEmptyState(icon, title, description) }
        ├── title: "Top tools — coming soon"
        ├── description: "Week-scoped tools breakdown lands in the next phase."
        └── ~30 LOC budget (≤45 cap)
```

### 3.2 Data flow

```
T4 substrate (already shipped):
  ProdInsights.weeklyMetrics(now:) → WeeklyMetrics
    ├── dailySeries: [DailyMetric] × 7
    ├── peakHour: Int?
    ├── wowDelta: Double?
    └── 5 streaks (commit / issue / huddle / focus / heavy)

T9 plumbing (THIS PHASE):
  InsightsReader.refresh()
    ├── ... 22 existing sequential fetches ...
    ├── try Task.checkCancellation()
    ├── let weeklyMetrics = try insights.weeklyMetrics(now: Date())   ← INSERT after recentLastCommit (line 200), before whereStopped composition (line 205)
    ├── try Task.checkCancellation()
    ├── ... whereStopped composition (line 205-216 unchanged) ...
    └── InsightsSnapshot(..., weeklyMetrics: weeklyMetrics)            ← INSERT in init params after whereStopped: (line 258)

InsightsSnapshot.weeklyMetrics: WeeklyMetrics = .empty   ← defaulted field

AnalyticsView (state-machine wrapper):
  switch reader.state {
    case .loading           → ProgressView + "Reading weekly metrics…"
    case .notConfigured(m)  → full-page LeafEmptyState (parity HomeView)
    case .empty(m)          → full-page LeafEmptyState (parity HomeView)
    case .error(m, lastK)   → errorBanner + AnalyticsContent(metrics: lastK?.weeklyMetrics ?? .empty)
    case .loaded(snap, _)   → AnalyticsContent(metrics: snap.weeklyMetrics)
  }
  .onAppear { reader.refresh() }

AnalyticsContent:
  if metrics == .empty → LeafCard { LeafEmptyState("Not enough data yet — keep working and check back tomorrow.") }
  else → populated 6-block layout
```

### 3.3 InsightsSnapshot field addition

Both inits modified (compact ~line 167-216 + convenience ~line 217-264). Defaulted-init trailing param:

```swift
public init(
    ...,                                            // existing 47 params
    whereStopped: WhereStoppedSnapshot? = nil,
    weeklyMetrics: WeeklyMetrics = .empty           // NEW — trailing defaulted
)
```

Convenience init forwards `weeklyMetrics: weeklyMetrics`. No `isEmpty` computed property modification (line 405-421) — `weeklyMetrics == .empty` is the empty signal; not joined into `isEmpty` Bool (which guards full-page LeafEmptyState fallback decision).

### 3.4 InsightsReader.refresh() insertion

Existing `try insights.recentLastCommit(maxAgeMs: 4 * 60 * 60 * 1000)` lives at lines 198-200. Insertion happens IMMEDIATELY AFTER:

```swift
let recentLastCommit = try insights.recentLastCommit(
    maxAgeMs: 4 * 60 * 60 * 1000
)
try Task.checkCancellation()
// Track-9 T9 — Analytics weekly metrics (7-day window, local-TZ midnight anchored).
// Pure read; T4 substrate ships ProdInsights+WeeklyMetrics with 5 streaks + WoW.
let weeklyMetrics = try insights.weeklyMetrics(now: Date())
try Task.checkCancellation()
// Path B — splice commit into deriver's snapshot ... (existing line 205+ continues)
```

InsightsSnapshot init invocation at line 259 gets new trailing param:

```swift
let snapshot = InsightsSnapshot(
    ...,                                            // existing params
    whereStopped: whereStopped,
    weeklyMetrics: weeklyMetrics                    // NEW
)
```

### 3.5 RootView routing — UNCHANGED

`RootView.swift:65` already routes `case .analytics: AnalyticsView()`. T9 only changes what `AnalyticsView()` body renders. Zero RootView changes.

---

## 4. Surface design

### 4.1 AnalyticsView (state-machine wrapper)

```swift
struct AnalyticsView: View {
    @Environment(InsightsReader.self) private var reader

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                header
                stateContent
            }
            .padding(LeafSpace.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { reader.refresh() }
    }

    private var header: some View {
        Text("Analytics")
            .font(LeafType.title.large)
            .foregroundStyle(LeafColor.text.primary)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch reader.state {
        case .loading:
            loadingState
        case .notConfigured(let msg):
            LeafCard(padding: .regular) {
                LeafEmptyState(icon: LeafIcons.brand.leaf, title: "Not configured", description: msg)
            }
        case .empty(let msg):
            LeafCard(padding: .regular) {
                LeafEmptyState(icon: LeafIcons.brand.leaf, title: "No data yet", description: msg)
            }
        case .error(let msg, let lastKnown):
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                LeafBanner(
                    tone: .danger,
                    title: "Couldn't load analytics",
                    description: msg,
                    ctaTitle: "Try again",
                    onCTA: { reader.refresh() }
                )
                AnalyticsContent(metrics: lastKnown?.weeklyMetrics ?? .empty)
            }
        case .loaded(let snapshot, _):
            AnalyticsContent(metrics: snapshot.weeklyMetrics)
        }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("Reading weekly metrics…")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.secondary)
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
    }
}
```

### 4.2 AnalyticsContent (consumer)

```swift
struct AnalyticsContent: View {
    let metrics: WeeklyMetrics

    var body: some View {
        Group {
            if metrics == .empty {
                emptyState
            } else {
                populated
            }
        }
        .animation(.easeInOut(duration: 0.25), value: metrics)
    }

    private var emptyState: some View {
        LeafCard(padding: .regular) {
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Not enough data yet",
                description: "Keep working and check back tomorrow."
            )
        }
    }

    private var populated: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xl) {
            WeekChipStrip(days: metrics.dailySeries)
            DailyFocusedChart(days: metrics.dailySeries)
            HStack(alignment: .top, spacing: LeafSpace.lg) {
                StreaksCard(metrics: metrics)
                PeakHourCallout(peakHour: metrics.peakHour)
            }
            WoWDeltaCallout(delta: metrics.wowDelta, dailySeries: metrics.dailySeries)
            TopToolsPlaceholder()
        }
    }
}
```

### 4.3 WeekChipStrip

7 horizontal chips. Each chip: vertical stack { 3-letter weekday label + focused-min `"42m"` or `"—"` if zero }. Today (rightmost, `dailySeries[6]`) рендерится с `accent.primary` background; remaining 6 — `surface.inset` background. Day-of-week derived from `dayStartMs` via cached `DateFormatter` (`"EEE"` format, locale-sensitive). Cached static formatter per Track-8 P9 C-4 carry pattern.

A11y: per-chip `accessibilityElement(children: .ignore) + accessibilityLabel("\(weekdayLong) \(formattedMin)")`.

### 4.4 DailyFocusedChart

First SwiftUI Charts usage in codebase. macOS 13+ requirement met (Leaf targets macOS 14+).

```swift
import Charts

struct DailyFocusedChart: View {
    let days: [DailyMetric]

    var body: some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                header
                chart
                legend
            }
        }
    }

    private var chart: some View {
        Chart(Array(days.enumerated()), id: \.offset) { _, day in
            BarMark(
                x: .value("Day", weekdayLabel(day.dayStartMs)),
                y: .value("Focused", day.focusedMin)
            )
            .foregroundStyle(LeafColor.accent.primary)

            LineMark(
                x: .value("Day", weekdayLabel(day.dayStartMs)),
                y: .value("AI ratio", day.aiRatio)
            )
            .foregroundStyle(LeafColor.status.info)
            .symbol(Circle().strokeBorder(lineWidth: 2))
            .symbolSize(40)
        }
        .chartYAxis { /* dual axis config */ }
        .chartXAxis { /* day labels */ }
        .frame(height: 200)
    }
}
```

Y-axis primary: focused-min, auto-scale 0..max × 1.15. Y-axis secondary: aiRatio 0..1 fixed. X-axis: 3-letter weekday labels.

### 4.5 StreaksCard

```swift
struct StreaksCard: View {
    let metrics: WeeklyMetrics

    var body: some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("STREAKS").leafSectionLabel()
                streakRow(icon: "chevron.left.forwardslash.chevron.right", label: "Commits", count: metrics.commitStreak)
                streakRow(icon: "checkmark.circle.fill", label: "Issues closed", count: metrics.issueCloseStreak)
                streakRow(icon: "bubble.left.and.bubble.right.fill", label: "Huddles", count: metrics.huddleStreak)
                streakRow(icon: "target", label: "Focus sessions", count: metrics.focusSessionStreak)
                streakRow(icon: "flame.fill", label: "Heavy days", count: metrics.heavyPulseStreak)
            }
        }
    }

    private func streakRow(icon: String, label: String, count: Int) -> some View {
        HStack(spacing: LeafSpace.sm) {
            Image(systemName: icon).foregroundStyle(LeafColor.accent.primary)
            Text(label).font(LeafType.body.regular).foregroundStyle(LeafColor.text.primary)
            Spacer()
            Text(streakText(count)).font(LeafType.body.regular).foregroundStyle(LeafColor.text.secondary)
        }
    }

    private func streakText(_ count: Int) -> String {
        switch count {
        case 0: return "—"
        case 1: return "1 day"
        default: return "\(count) days"
        }
    }
}
```

### 4.6 PeakHourCallout

```swift
struct PeakHourCallout: View {
    let peakHour: Int?

    var body: some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("PEAK HOUR").leafSectionLabel()
                dotStrip
                Text(peakHourLabel).font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)
            }
        }
    }

    private var dotStrip: some View {
        HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                RoundedRectangle(cornerRadius: 1)
                    .fill(hour == peakHour ? LeafColor.accent.primary : LeafColor.text.tertiary)
                    .frame(width: 4, height: 12)
            }
        }
    }

    private var peakHourLabel: String {
        guard let hour = peakHour else { return "—" }
        return String(format: "%02d:00", hour)
    }
}
```

### 4.7 WoWDeltaCallout

```swift
struct WoWDeltaCallout: View {
    let delta: Double?
    let dailySeries: [DailyMetric]

    var body: some View {
        LeafCard(padding: .regular) {
            HStack(spacing: LeafSpace.lg) {
                sparkline.frame(width: 160, height: 40)
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(deltaText).font(LeafType.title.medium).foregroundStyle(deltaTone)
                    Text("vs last week").font(LeafType.label).foregroundStyle(LeafColor.text.tertiary)
                }
                Spacer()
            }
        }
    }

    private var sparkline: some View {
        Chart(Array(dailySeries.enumerated()), id: \.offset) { idx, day in
            LineMark(
                x: .value("Day", idx),
                y: .value("Focused", day.focusedMin)
            )
            .foregroundStyle(LeafColor.accent.primary)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    private var deltaText: String {
        guard let d = delta else { return "—" }
        let pct = Int(round(d * 100))
        return String(format: "%+d%%", pct)
    }

    private var deltaTone: Color {
        guard let d = delta else { return LeafColor.text.tertiary }
        if d > 0 { return LeafColor.status.success }
        if d < 0 { return LeafColor.status.warning }
        return LeafColor.text.secondary
    }
}
```

### 4.8 TopToolsPlaceholder

```swift
struct TopToolsPlaceholder: View {
    var body: some View {
        LeafCard(padding: .regular) {
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Top tools — coming soon",
                description: "Week-scoped tools breakdown lands in the next phase."
            )
        }
    }
}
```

---

## 5. Acceptance gates

10 gates mirroring T8 pattern.

| AC | Description | Verification |
|---|---|---|
| AC-1 | 5/5 xcodebuild Debug schemes SUCCESS | `just build-all` — LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP all SUCCEEDED |
| AC-2 | SPM tests: baseline +N net new, 0 failures | `swift test --package-path Packages/LeafCore` |
| AC-3 | `just check-tokens` 3-tier clean | BASE + MIGRATION + RETIRED tier pass |
| AC-4 | Substrate diff empty: DB | `git diff feature/track-9-substrate^..HEAD -- Packages/LeafCore/Sources/LeafCore/DB/` returns empty |
| AC-5 | Substrate diff empty: ShareEventTypeRegistry | `git diff -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` returns empty |
| AC-6 | Substrate diff empty: LeafMCP | `git diff -- LeafMCP/` returns empty |
| AC-7 | Privacy walkback narrow grep — 0 hits forbidden fields в T9 file scope | `grep -nE "absolute_path\|full_comment_body\|raw_email\|notes_body\|email_subject\|note_body\|file_contents\|raw_prompt\|tool_input\|tool_response\|response_body\|prompt" Leaf/Views/Window/Analytics/` returns 0 lines |
| AC-8 | LOC budgets per component | AnalyticsView ≤120, AnalyticsContent ≤120, WeekChipStrip ≤80, DailyFocusedChart ≤140, StreaksCard ≤100, PeakHourCallout ≤90, WoWDeltaCallout ≤100, TopToolsPlaceholder ≤45 |
| AC-9 | InsightsSnapshot defaulted-init roundtrip + .empty equality test | `WeeklyMetrics == .empty` Equatable check ships T4; new public test verifies field plumbing via roundtrip |
| AC-10 | Master spec §9.1 C-23 marker flipped to **[RESOLVED T9]** | Inline status markers in `2026-05-18-track-8-home-ux-design.md` §9.1 — grep `C-23` → contains `[RESOLVED T9 — commit <sha>]` |

---

## 6. Testing strategy

### 6.1 Public LeafCoreTests (additions)

`Packages/LeafCore/Tests/LeafCoreTests/Insights/InsightsSnapshotTests.swift`:

1. `testInsightsSnapshot_DefaultedInit_WeeklyMetricsDefaultsToEmpty` — construct via convenience init без `weeklyMetrics:` param → assert `snapshot.weeklyMetrics == .empty`.
2. `testInsightsSnapshot_FullInit_WeeklyMetricsRoundtrip` — construct full init с custom `WeeklyMetrics` → assert `snapshot.weeklyMetrics == custom`.

### 6.2 View tests (minimal, codebase precedent — view tests sparse)

Skip — minimal view tests aren't a codebase pattern (HomeView / TodayBlock / WhereStoppedBlock / etc. have no direct snapshot view tests). T9 inherits this convention. Verification falls to:
- Independent code review (Stage 6)
- Manual UI smoke (Stage 7)

### 6.3 No sentinel-injection regression test

T9 reads only aggregate metrics from substrate (`dailySeries.focusedMin`, `peakHour: Int?`, `wowDelta: Double?`, 5 streak Int counters). No body / title / payload field access — pattern parity P3/P4/P5/P7 (Track-8 + Track-9 lineage). Master spec §6 line 285 documents this exemption category.

### 6.4 Net test delta target

+2 net new tests (InsightsSnapshot defaulted-init roundtrip × 2). Baseline post-T8: 2988 XCTest + 45 Swift-Testing = 3033 total. T9 target: ~3035 total.

---

## 7. Privacy walkback (ADR-010)

T9 reads only typed `Int`/`Double` substrate fields. No raw payload access. No body / title / preview text crossing the UI boundary. T4 substrate ADR-010 walkbacks (allowlist-only SQL) cover capture-path. T9 view code is purely consumer.

**AC-7 grep target paths:**
- `Leaf/Views/Window/Analytics/AnalyticsView.swift`
- `Leaf/Views/Window/Analytics/AnalyticsContent.swift`
- `Leaf/Views/Window/Analytics/Blocks/*.swift`

Forbidden field-name fragments (mirror T8 AC-7): `absolute_path|full_comment_body|raw_email|notes_body|email_subject|note_body|file_contents|raw_prompt|tool_input|tool_response|response_body|prompt`.

Expected: 0 lines hit.

---

## 8. Risks + mitigations

| Risk | Mitigation |
|---|---|
| **First SwiftUI Charts usage in codebase** — unknowns в API + token discipline | Wrap all Charts color/font/style API в Leaf tokens. Manual smoke at Stage 7 verifies render correctness. Per-component LOC budget allows iteration. |
| **`check-tokens` BASE/MIGRATION tier flags Charts internals** — false positive risk | `Leaf/Views/Window/Analytics/Blocks/` lives под MIGRATION tier — bans raw `Color.` (not `LeafColor.`), raw padding ints, raw cornerRadius ints. Charts API consumes `ShapeStyle` parameters — passing `LeafColor.accent.primary` (which IS `Color`) satisfies token tier. Pre-Stage 7 dry-run `just check-tokens` mid-implementation catches issues early. |
| **Dual-axis Y in Chart not visible** — Charts secondary axis can be subtle | Render aiRatio Line как PointMark + LineMark combination. Secondary Y axis explicit positioning (right side). Manual smoke verifies on real Mac. |
| **`weeklyMetrics: WeeklyMetrics = .empty` defaulted-init fixture sweep risk** — 23 fixture callsites | Defaulted trailing param — zero existing callsite touches required. P3-P7 precedent (5 prior defaulted-init iterations) — pattern proven. |
| **InsightsSnapshot SQL fetch failure** — `refresh()` adds 23rd call; if `weeklyMetrics(now:)` throws, entire refresh fails и render → error state | Acceptable. T6 last-known retention pattern handles graceful degrade. Substrate ships `.empty` for stub/iOS-future paths; throw scenario means real corruption (catastrophic, signals real error). |
| **`PeakHourCallout` nil rendering ambiguous** — "—" + muted strip = "no peak yet" or "feature broken"? | Card title "PEAK HOUR" + bottom label "—" semantic; honest. Users see "—" early in DB lifetime; populates as activity accrues. Acceptable. |
| **Charts auto-animation conflicts с outer .animation(.easeInOut, value: metrics)** — double animation | Charts API auto-animates on data change; outer modifier on `value: metrics` provides cross-fade for empty↔populated branch transitions. They compose cleanly; tested via manual smoke. |
| **WoWDelta sparkline + main DailyFocusedChart redundancy** — same source data, two viz | Different visual purposes: chart = detail (per-day height comparison), sparkline = trend at-a-glance. Master spec §3.5 contract. Acceptable. |

---

## 9. Carry-overs

### 9.1 Reconciles Track-8 master spec §9.1

- **C-23** Analytics surface real content → **[RESOLVED T9 — commit <sha>]** marker injected during Stage 8 ship.

### 9.2 New carries to Track-9 master spec §9.3 (T10 wrap inventory)

| ID | Description | Owner |
|---|---|---|
| C-34 | Master spec §T9 line 218 wording amendment — `WeeklyMetrics?` → `WeeklyMetrics = .empty` (defaulted). | T10 wrap doc update. |
| C-35 | Master spec §T9 line 217 wording amendment — "8 day chips" → "7 day chips" (substrate fidelity per T4 D-8). | T10 wrap doc update. |
| C-36 | Master spec §T9 line 217 wording amendment — "TopToolsCard" → "TopToolsPlaceholder" (substrate-gap honest stub). | T10 wrap doc update. |
| C-37 | Master spec §T9 line 217 wording amendment — "24h mini-heatmap" → "24-dot strip" (substrate has only `peakHour: Int?`, no per-hour distribution). | T10 wrap doc update. |
| C-38 | Real TopToolsCard — requires substrate addition `topToolsWeek: [SurfacePill]` или separate `weekTopSurfaces(now:)` deriver. T6 SurfacePill discriminator coupling. | Post-Track-9 phase. |
| C-39 | Per-hour distribution heatmap PeakHourCallout — requires substrate enrichment (per-hour bucket distribution across week). | Post-Track-9 substrate phase. |
| C-40 | Per-day chart drill-down tap → detail screen + `RouteCoordinator.pushAnalytics*` + `AppRoute.analytics(...)` enum case. | Post-Track-9 if user demand emerges. |
| C-41 | Multi-week variant (30d / 90d) — parallel `metrics(period:)` API. | Post-Track-9 if user ask. |
| C-42 | Localization — labels "STREAKS" / "PEAK HOUR" / "vs last week" / "Commits" / "Issues closed" / "Huddles" / "Focus sessions" / "Heavy days" hardcoded English. | Separate localization track (Track-8 P9 C-19 family). |
| C-43 | View-layer test coverage — block-init smoke tests + a11y label composition tests. Codebase precedent allows skipping; if test infrastructure for `Leaf/` target lands, T9 view tests are productive future addition. | Post-Track-9 if Leaf test target lands. |

---

## 10. Implementation map (Stage 4 plan owns full decomposition)

Atomic step decomposition lives в `.claude/plans/track-9-T9.md`. Outline preview:

1. **Task 1** — `InsightsSnapshot.weeklyMetrics = .empty` defaulted field в обоих init signatures + 2 public roundtrip tests (TDD red → green).
2. **Task 2** — `InsightsReader.refresh()` 23rd SQL call insertion + threading through to `InsightsSnapshot(...)` init.
3. **Task 3** — `AnalyticsView` full rewrite — state-machine wrapper, `.onAppear { reader.refresh() }`, 5 state branches.
4. **Task 4** — `AnalyticsContent` consumer view — empty/populated branch + animation.
5. **Task 5** — `WeekChipStrip` block — 7 chips + today highlighting + a11y.
6. **Task 6** — `DailyFocusedChart` block — first Charts usage, dual-axis BarMark + LineMark.
7. **Task 7** — `StreaksCard` block — 5 rows + SF Symbols.
8. **Task 8** — `PeakHourCallout` block — 24-dot strip + peak highlight + nil handling.
9. **Task 9** — `WoWDeltaCallout` block — sparkline LineMark + formatted delta + nil handling.
10. **Task 10** — `TopToolsPlaceholder` block — honest "coming soon" card.
11. **Task 11** — Stage 6 review fixes + master spec §9.1 C-23 marker flip + current-state.md update + final verification gates.

Per-task acceptance criteria, file paths, LOC budgets — Stage 4 plan.

---

## 11. References

- Track-9 master design: `2026-05-19-track-9-substrate-enrichment-design.md`
- T4 spec (substrate consumed): `2026-05-20-track-9-T4-weekly-metrics-deriver.md`
- T7 spec (defaulted-init snapshot wiring precedent): `2026-05-21-track-9-T7-where-stopped-4line.md`
- T8 spec (acceptance gate pattern parity): `2026-05-21-track-9-T8-inbox-feeder-expansion.md`
- Track-8 master spec §9.1 (carry C-23): `2026-05-18-track-8-home-ux-design.md`
- Phase 8.8 P8 spec (Activity → Analytics rename precedent): `2026-05-19-phase-8-8-analytics-rename.md`
- ADR-010 walkback substrate: whitepaper `privacy-security/what-we-dont-capture.md`
