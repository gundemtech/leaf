# Track-9 T4 — Analytics substrate (`weeklyMetrics` deriver)

**Status:** SHIPPED — Stage 5 done. 8 moat scenarios + 4 public + 1 stub = **13 net new tests** (SPM 2913 → 2926, 0 failures, 4 skipped). 5/5 xcodebuild Debug schemes green. All 4 substrate-purity zero-diff invariants verified. Privacy walkback narrow grep — 0 hits. `just check-tokens` 3-tier clean.
**Track-9 master design:** [`2026-05-19-track-9-substrate-enrichment-design.md`](./2026-05-19-track-9-substrate-enrichment-design.md) §T4 line 172-176.
**T1 spec (precedent — substrate-only deriver pattern):** [`2026-05-19-track-9-T1-collector-payload-extensions.md`](./2026-05-19-track-9-T1-collector-payload-extensions.md).
**T3 spec (precedent — Track-9 deriver-side synthesis pattern):** [`2026-05-20-track-9-T3-github-inbox-feeder.md`](./2026-05-20-track-9-T3-github-inbox-feeder.md).
**Branch:** `feature/track-9-substrate` (off T3 wrap tip `3bb9f26a`). FF после T4 acceptance.
**Ship classification:** Pure substrate, fully silent — UI неизменна (Phase 8.8 `AnalyticsView` placeholder остаётся), no new event_kinds / migrations / MCP tools / ShareEventTypeKey delta. T9 phase позже потребляет деривер через `InsightsReader.refresh()` → `InsightsSnapshot.weeklyMetrics` → real Analytics surface.

---

## 1. Scope

**In scope:**

1. **`WeeklyMetrics` public value type** в `Packages/LeafCore/Sources/LeafCore/Insights/WeeklyMetrics.swift`. Equatable/Hashable/Sendable. 8 публичных полей: `dailySeries: [DailyMetric]` (7 entries, oldest → newest), `peakHour: Int?`, `wowDelta: Double?`, 5 streak counters (`commitStreak / issueCloseStreak / huddleStreak / focusSessionStreak / heavyPulseStreak: Int`). `.empty` static.
2. **`DailyMetric` public value type** в том же файле. Equatable/Hashable/Sendable. 5 публичных полей: `dayStartMs: Int64` (local-TZ midnight), `focusedMin: Int`, `sessionsCount: Int`, `commitsCount: Int`, `aiRatio: Double`.
3. **`DerivedInsights.weeklyMetrics(now: Date) throws -> WeeklyMetrics`** protocol method добавлен в `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift`. Protocol-extension default возвращает `.empty` (graceful для stubs / iOS-future). `StubInsights` explicit override → `.empty`.
4. **`ProdInsights+WeeklyMetrics.swift`** SQL+Swift impl в LeafCorePrivate moat (`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+WeeklyMetrics.swift`, gitignored). 7-day window анкорится на local-TZ midnight через `Calendar.current` (precedent: Phase 4.7.A `dailyTouchedIssuesCount`). Internal helpers — `dayBoundaries(now:calendar:)` / `streakBackFromDay(predicate:)` / `peakHourBucket(periodStart:periodEnd:)` / `wowFormula(this:last:)`.
5. **Streak event-source mapping** (см. §3.4): `commitStreak` ← `gh_commit_pushed` events / `issueCloseStreak` ← `linear_status_transition` w/ completed type / `huddleStreak` ← `slack_huddle_state_change` started transitions / `focusSessionStreak` ← derived focus sessions ≥10 min / `heavyPulseStreak` ← M018 `intensity_aggregates.bucket = 'heavy'` rows.
6. **Tests (Q6 decision)**: ~7 moat scenario tests в `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsWeeklyMetricsTests.swift` + ~3 public tests в `Packages/LeafCore/Tests/LeafCoreTests/Insights/WeeklyMetricsTests.swift` + 1 `DerivedInsightsStub` default test (extension to existing `DerivedInsightsStubTests` или sibling test file).
7. **No new SQLCipher migrations**: M001-M018 + M024 + M026 + M027 = 30 tables preserved (T1+T2+T3 added zero). M018 `intensity_aggregates` уже существует Track-4 S3.
8. **No new event_kinds**: T4 reads existing `gh_commit_pushed` / `linear_status_transition` / `slack_huddle_state_change` / focus session derivative / M018 intensity rows. Zero capture-path emission.
9. **No new MCP tools**: registry frozen at 15 (Phase 4.7.B + Track-1 D3). `get_weekly_metrics` MCP tool — post-Track-9 если будет ask (master spec §10 carry).
10. **No ShareEventTypeKey delta**: registry frozen at T3 wrap **198**. Pure read-side phase.
11. **No `InsightsReader` / `InsightsSnapshot` touch**: T4 ships только deriver method. T9 phase wires `refresh()` fetch + `Snapshot.weeklyMetrics: WeeklyMetrics?` defaulted field.
12. **No UI surface changes**: `AnalyticsView.swift` placeholder Phase 8.8 unchanged.

**Hard exclusion (out of T4 — carry list):**

- **`topTools: [SurfacePill]` week-scoped field** — DEFERRED to T6 (Q1 decision). T6 master spec §T6 line 191-196 уже владеет `SurfacePill.kind: .captureTime | .actionNoun` discriminator refactor + family-grouped aggregation SQL. T6 либо (a) добавит `WeeklyMetrics.topTools` defaulted-init расширением (mirror Track-9 T1 `lastAppBundleID: String? = nil` precedent), либо (b) shipнёт отдельный `weekTopSurfaces(now:)` deriver method который T9 view вызовет напрямую. T4 не предвосхищает T6 shape.
- **Multi-metric WoW deltas** (`wowDeltas` struct с 4 metrics — focused / aiRatio / sessions / commits) — YAGNI до T9 UI mockup ask. Master spec §T9 `WoWDeltaCallout` показывает single sparkline (focus-time). T4 ships `wowDelta: Double?` single field; future expansion возможен через `wowDeltas: WoWDeltas` parallel field или rename rebrand.
- **Per-day surface time breakdown** (`DailyMetric.surfaceBreakdown: [SurfaceTime]`) — YAGNI. Master spec §T9 `DailyFocusedChart` читает только `focusedMin` per day, no per-day per-surface slicing.
- **Variable-period signature** (`weeklyMetrics(period: DateInterval)` или `monthlyMetrics`/`metrics(period:)`) — Q2 decision Option A. Future 30-day variant если ask — parallel method, не rename.
- **`InsightsReader.refresh()` fetch wiring + `InsightsSnapshot.weeklyMetrics` field** — T9 scope (UI consumer phase). T4 пишет deriver substrate; T9 потребляет.
- **`AnalyticsView.swift` real content (chart + cards + sparklines)** — T9 scope (master spec §T9).
- **`InsightsSnapshot.recentActivity` orphan drop** (Track-8 P9 carry C-24) — T10 wrap scope, не T4.
- **`get_weekly_metrics` MCP tool** — post-Track-9 если будет ask.
- **T5..T10 phases** — separate phases per Track-9 master design.

### 1.1 Deviations from Track-9 master spec §T4

Master spec §T4 line 174:
> `ProdInsights+WeeklyMetrics.swift` SQL math: 8 × `TodayMetrics` daily aggregation, WoW deltas vs days[-7..-13], peak hour from attention-time histogram, week-scoped top tools (reuses T6 family-grouped aggregation), 5 streaks (commit / issue-close / huddle / focus-session / heavy-pulse).

**T4 implements 7-day window (not 8) + drops top tools entirely.**

**7 vs 8 days** — master spec wording "8 × `TodayMetrics` daily aggregation" is imprecise. `WeekChipStrip` (master spec §T9 line 217) описывает "8 day chips" — это "today + last 7 days" UI rendering pattern (current day partial + 7 completed days). T4 substrate ship'ает `dailySeries: [DailyMetric]` size 7 (last 7 completed days OR today + 6 trailing — locked in §3.1 below). Если T9 потребует 8th cell для "today partial", he может или добавить отдельный `todayMetrics(now:)` call (уже substrate has это Phase 8.1), или расширить `dailySeries` defaulted-init в T9 phase. Simpler: T4 ship 7 days, T9 composes с today's `TodayMetrics` если нужно 8th chip.

**Top tools dropped** — Q1 decision. Coupling к T6 SurfacePill refactor создаёт двойную миграцию когда T6 ships. Carry полностью к T6.

**Net deltas updated:**
- WeeklyMetrics struct shape: 8 fields (not 9 — `topTools` carried к T6).
- DailyMetric shape: 5 fields (no `surfaceBreakdown`).
- ShareEventTypeKey registry +**0** (no new event_kinds).
- SQLCipher migrations +**0** (no DDL).
- MCP tools +**0**.

Master spec §T4 to be amended в T10 wrap. T4 spec is the authoritative implementation contract.

---

## 2. Decisions taken (Stage 2 brainstorm output)

| # | Question | Decision | Rationale |
|---|---|---|---|
| D-1 | `WeeklyMetrics` shape scope | **Option A Lean MVP** — `dailySeries[7]` + `peakHour` + single `wowDelta` + 5 streak counters. `topTools` carry к T6, multi-metric WoW + per-day surface breakdown YAGNI'd. | Master spec §T9 UI mockup рендерит 6 components (WeekChipStrip / DailyFocusedChart / StreaksCard / PeakHourCallout / TopToolsCard / WoWDeltaCallout). 5 of 6 satisfied Lean MVP. TopToolsCard delegated к T6 ownership (T6 владеет SurfacePill discriminator refactor — coupling cost > value). Multi-metric WoW + per-day surface breakdown YAGNI до T9 UI explicit ask. |
| D-2 | Signature | **`weeklyMetrics(now: Date) throws -> WeeklyMetrics`** (NOT `period: DateInterval`). | Phase 8.1 `todayMetrics(now:)` / `youNowState(now:)` precedent. Locks "week = 7 days" invariant в impl — streaks/peakHour/WoW semantics only valid на 7-day window. Variable-period signature future-proofs 30d/90d use case но T9 mockup статичный 7-day — YAGNI risk. `now: Date` тривиально testable (pass fixed Date в fixture). |
| D-3 | T6 dependency | **Zero T6 dependency.** `topTools` полностью carry к T6 (либо field-extension Optional defaulted-init, либо отдельный `weekTopSurfaces(now:)` deriver). | Q1 decision (Option A) eliminates coupling. T4 ship'ается до или после T6 без ordering constraint. |
| D-4 | Day boundary granularity | **Local TZ midnight** через `Calendar.current.startOfDay(for:)`. NOT UTC. | Phase 4.7.A `dailyTouchedIssuesCount` precedent. User mental model "понедельник/вторник/…" follows local. UTC ломает edge cases (Sun 23:00 local commit = Mon UTC рвёт streak). |
| D-5 | Streak cold-tick semantic | **Standard semantic, no nil/sentinel.** Streak = consecutive days back from today (inclusive), max 7-day lookback. `commitStreak = 0` валидное состояние — "no qualifying activity today AND no recent streak". Cold-tick (DB <7 days history) handled naturally — streak counts только existing populated days. | Mirror GitHub contribution streak pattern. UI рендерит "0 days" без trouble. Avoiding Optional Int? simplifies 5 callsites в T9 UI. |
| D-6 | WoW delta cold-tick semantic | **`wowDelta: Double?` nil iff `last_week_focused == 0`**, else `(this − last) / last`. | Mirror `linearCompletionRate` precedent (`nil ↔ completed == 0`). Single rule simplifies impl. Cold-install user (last week zero focused) → wowDelta=nil → UI renders "—". Sentinel `Double.infinity` rejected (Swift idiom violation; UI must decode `.isInfinite`). |
| D-7 | `dailySeries` ordering | **Oldest → newest** (`dailySeries[0]` = day-6, `dailySeries[6]` = today). | UI chart renders left-to-right time progression naturally. Matches typical chart library convention. |
| D-8 | `dailySeries` window | **7 entries, anchored at local-TZ midnight from `now`.** `today = startOfDay(now)`, series spans `[today − 6d .. today]` inclusive. | Q1 + Q4 lock. Master spec "8 day chips" UI artifact composed in T9 by appending today's `TodayMetrics` если нужно (or expanding dailySeries в T9 phase). Substrate ship 7 days, simple invariant. |
| D-9 | `peakHour` source | **Hour-of-day bucket from attention-time** (events where `signal_type='attention'`) aggregated за all 7 days в local-TZ hour buckets. Tie-break: lowest hour wins (determinism lock). nil iff total attention minutes across week ≤ insignificant threshold (`< 5 min` raw cap — guards against single random event). | UI shows 24h mini-heatmap callout. Hour-of-day pattern across week — single peak. Tie-break determinism critical для testability. |
| D-10 | `wowDelta` metric | **Focused-min based.** `this_week_focused = sum(dailySeries[0..6].focusedMin)`, `last_week_focused = sum(focusedMin from days[-7..-13])`. | Master spec §T9 `WoWDeltaCallout` rendered sparkline of focus-time. Other metrics (aiRatio / sessions / commits) future expansion if UI asks. |
| D-11 | Streak source: `commitStreak` | `gh_commit_pushed` event_kind in the action stream, scoped to the [dayStart, dayEnd) window. Real query body in moat. | Track-9 T1 `recentLastCommit` precedent (same event-kind discriminator). |
| D-12 | Streak source: `issueCloseStreak` | `linear_status_transition` event_kind WHERE `payload_json.transition_type='completed'`. Phase 4.6.B precedent. | Mutually-exclusive transition bucketing (Phase 4.6.B). "Completed" = `WorkflowState.type='completed'`. |
| D-13 | Streak source: `huddleStreak` | `slack_huddle_state_change` event_kind WHERE `payload_json.state='started'` (NOT every state change — counts huddle-initiation days). Phase 4.4 precedent. | Symmetric с focus-session streak (counts initiation days, not continuous-presence days). |
| D-14 | Streak source: `focusSessionStreak` | Derived focus sessions ≥10 min duration. Computed via reuse of existing `focusSessions(period:)` semantics (read attention events, aggregate via `FocusSessionAggregator` logic). Counts days where ≥1 focus session ≥10 min landed. | Existing substrate primitive. Threshold 10 min aligns с Phase 4.6.A focus session min cutoff. |
| D-15 | Streak source: `heavyPulseStreak` | M018 `intensity_aggregates` table rows WHERE row satisfies T4-defined heavy threshold predicate (M018 stores raw counters per minute — no pre-baked bucket column). T4 threshold (deriver-defined): `keystrokes ≥ 60 OR mouse_moves ≥ 120 OR app_switches ≥ 5` per minute. Counts days where ≥1 minute-row satisfies predicate. | Track-4 S3 `IntensityBucketAccumulator` ships raw counters — bucket classification happens at deriver time. T4 locks pragmatic threshold (≈1 keystroke/sec sustained, или dense mouse activity, или high context-switch). Threshold const lives in moat (`HeavyIntensityThreshold` struct) — refinement opt-in future without protocol shape change. |
| D-16 | `DailyMetric.focusedMin` SQL | Sum of focus session durations (≥10 min sessions) anchored at day. Reuses focus session aggregation; sum truncated to Int minutes. | Mirror Phase 8.1 `TodayMetrics.focusedMin` semantics. |
| D-17 | `DailyMetric.sessionsCount` SQL | Count of distinct focus sessions ≥10 min that day. | Mirror Phase 8.1 `TodayMetrics.sessionsCount` semantics. |
| D-18 | `DailyMetric.commitsCount` SQL | `COUNT(*) WHERE event_kind='gh_commit_pushed' AND ts_ms IN [dayStart, dayEnd)`. | Single SQL pass. |
| D-19 | `DailyMetric.aiRatio` SQL | Reuses existing `aiRatio(period:)` semantics applied к day-bounded period. Returns 0.0..1.0; 0.0 если no attention in day. | Mirror Phase 8.1 `TodayMetrics.aiRatio` semantics. |
| D-20 | Tests strategy | **Moat integration with scenario decomposition (Recommended)** — ~7-8 fixture-seeded scenarios в `ProdInsightsWeeklyMetricsTests` + 3 public `WeeklyMetricsTests` (Equatable + `.empty` shape) + 1 Stub default test. No sentinel-injection (T4 reads aggregates not bodies, mirror Track-8 P3/P4/P5/P7 + Track-9 T1 precedent). | T3 precedent (6 scenarios per fixture variant). Per-scenario tests localize failures (cold-tick / week-off / streak-break / TZ-boundary / tie-break / empty DB). |
| D-21 | Migrations | **0 new SQLCipher migrations** (M001-M018 + M024 + M026 + M027 = 30 baseline + T1+T2+T3 = 0 delta = **30**). | Master spec §5.2 — M028 carved out at T7. T4 reads existing tables only. |
| D-22 | MCP tools | **0 new tools.** `get_weekly_metrics` carry post-Track-9. | T4 scope = substrate only. T9 phase либо wires direct deriver call from view, либо адд'ит MCP tool как separate scope. |
| D-23 | Settings UI | **None.** No user-facing toggles. | Pure substrate. T9 surfaces real Analytics; toggles если будут — at T9 design. |
| D-24 | Branch off | **`feature/track-9-substrate` at T3 wrap tip `3bb9f26a`**. FF after T4 acceptance. | Mirror T3-off-T2 chain. T4..T9 sequence на same collective branch. |
| D-25 | Tests split: public vs LeafCorePrivate moat | **Public** (`LeafCoreTests`): WeeklyMetrics + DailyMetric Equatable round-trip + `.empty` static shape + `DerivedInsightsStub.weeklyMetrics` default returns `.empty`. **Moat** (`LeafCorePrivateTests`): all 7 fixture scenarios (happy path / cold tick / week off / streak breaks / peak hour tie / TZ boundary / empty DB). SQL math + fixture seeding в moat — DB shape + GRDB query path moat-only. | T1+T3 precedent. Public surface validates type contract; moat validates SQL correctness. |
| D-26 | Internal helpers in moat | Three internal-scoped pure helpers: `dayBoundaries(now:calendar:) -> [(start: Int64, end: Int64)]` (returns 7-day boundaries oldest→newest), `streakBackFromDay(eventCountPerDay: [Int]) -> Int` (counts consecutive non-zero from tail), `wowFormula(thisWeekFocused: Int, lastWeekFocused: Int) -> Double?` (returns nil iff last==0). PeakHour computation inline (single-SQL). | Pure helpers enable unit-test reuse если позже захочется. Internal-scoped (not public) — surface area minimal. |

---

## 3. Architecture

### 3.1 Component map

```
LeafCore (public)
├── Insights/WeeklyMetrics.swift              (NEW)
│   ├── struct WeeklyMetrics                  (8 fields + .empty)
│   └── struct DailyMetric                    (5 fields)
│
├── Insights/DerivedInsights.swift            (MODIFIED — +1 protocol method + default)
│   ├── protocol DerivedInsights
│   │   └── func weeklyMetrics(now:) throws -> WeeklyMetrics
│   ├── extension DerivedInsights (default impl)
│   │   └── func weeklyMetrics(now:) → .empty
│   └── StubInsights
│       └── func weeklyMetrics(now:) → .empty   (explicit override matches existing pattern)
│
LeafCorePrivate (moat, gitignored)
└── Prod/Insights/ProdInsights+WeeklyMetrics.swift   (NEW)
    └── extension ProdInsights: DerivedInsights
        └── func weeklyMetrics(now: Date) throws -> WeeklyMetrics
            ├── boundaries = dayBoundaries(now:, calendar: .current)  // 7 (start,end) pairs
            ├── lastWeekBoundaries = dayBoundaries(now: calendar.date(byAdding: .day, value: -7, to: now)!)  // for WoW
            ├── dailySeries = boundaries.map { fetchDailyMetric(start:, end:) }
            ├── peakHour = computePeakHour(weekStart, weekEnd)
            ├── thisWeekFocused = dailySeries.reduce(0) { $0 + $1.focusedMin }
            ├── lastWeekFocused = lastWeekBoundaries.reduce(0) { $0 + fetchFocusedMin($1.start, $1.end) }
            ├── wowDelta = wowFormula(this: thisWeekFocused, last: lastWeekFocused)
            ├── commitStreak = streakBackFromDay(eventCountPerDay: commitCountsPerDay)
            ├── issueCloseStreak = streakBackFromDay(eventCountPerDay: linearCompletedCountsPerDay)
            ├── huddleStreak = streakBackFromDay(eventCountPerDay: huddleStartedCountsPerDay)
            ├── focusSessionStreak = streakBackFromDay(eventCountPerDay: focusSessionCountsPerDay)
            ├── heavyPulseStreak = streakBackFromDay(eventCountPerDay: heavyBucketCountsPerDay)
            └── return WeeklyMetrics(...)
```

### 3.2 Data flow

T4 ships **deriver-only**. No event capture, no DB writes, no schema migration. Pure read.

```
events table (unchanged):
  rows already populated Phase 4.x + Track-4 + Track-6 + Track-9 T1/T2/T3
    ├── gh_commit_pushed              ← commitStreak source + DailyMetric.commitsCount
    ├── linear_status_transition      ← issueCloseStreak source
    ├── slack_huddle_state_change     ← huddleStreak source
    ├── attention events              ← peakHour, focusSessionStreak, DailyMetric.focusedMin/sessionsCount
    └── aiCollaboration events        ← DailyMetric.aiRatio

intensity_aggregates table (M018, unchanged):
  bucket rows (light/medium/heavy)    ← heavyPulseStreak source

ProdInsights+WeeklyMetrics.swift (NEW deriver):
  ├── computes 7 daily aggregations + peakHour + wowDelta + 5 streaks
  └── returns WeeklyMetrics
```

### 3.3 `WeeklyMetrics` + `DailyMetric` public shape

```swift
import Foundation

public struct WeeklyMetrics: Equatable, Hashable, Sendable {
    /// 7 entries, oldest → newest. `dailySeries[0]` = day-6, `dailySeries[6]` = today.
    /// Anchored at local-TZ midnight via `Calendar.current.startOfDay(for:)`.
    public let dailySeries: [DailyMetric]

    /// 0..23 hour bucket with maximum attention-time across the 7-day window.
    /// nil iff total attention minutes < 5 (insignificant data).
    /// Tie-break: lowest hour wins (determinism).
    public let peakHour: Int?

    /// (this_week_focused - last_week_focused) / last_week_focused.
    /// nil iff last_week_focused == 0 (no comparable baseline).
    public let wowDelta: Double?

    /// Consecutive days back from today w/ ≥1 gh_commit_pushed. Max 7.
    public let commitStreak: Int

    /// Consecutive days back from today w/ ≥1 Linear status_transition.completed. Max 7.
    public let issueCloseStreak: Int

    /// Consecutive days back from today w/ ≥1 slack_huddle_state_change.started. Max 7.
    public let huddleStreak: Int

    /// Consecutive days back from today w/ ≥1 focus session ≥10 min. Max 7.
    public let focusSessionStreak: Int

    /// Consecutive days back from today w/ ≥1 intensity_aggregates.bucket='heavy' row. Max 7.
    public let heavyPulseStreak: Int

    public static let empty = WeeklyMetrics(
        dailySeries: Array(repeating: DailyMetric.empty, count: 7),
        peakHour: nil,
        wowDelta: nil,
        commitStreak: 0,
        issueCloseStreak: 0,
        huddleStreak: 0,
        focusSessionStreak: 0,
        heavyPulseStreak: 0
    )

    public init(
        dailySeries: [DailyMetric],
        peakHour: Int?,
        wowDelta: Double?,
        commitStreak: Int,
        issueCloseStreak: Int,
        huddleStreak: Int,
        focusSessionStreak: Int,
        heavyPulseStreak: Int
    ) {
        self.dailySeries = dailySeries
        self.peakHour = peakHour
        self.wowDelta = wowDelta
        self.commitStreak = commitStreak
        self.issueCloseStreak = issueCloseStreak
        self.huddleStreak = huddleStreak
        self.focusSessionStreak = focusSessionStreak
        self.heavyPulseStreak = heavyPulseStreak
    }
}

public struct DailyMetric: Equatable, Hashable, Sendable {
    /// Local-TZ midnight epoch ms for the day.
    public let dayStartMs: Int64

    /// Sum of focus session minutes (≥10 min sessions) that day. Truncated to Int.
    public let focusedMin: Int

    /// Distinct focus sessions ≥10 min that day.
    public let sessionsCount: Int

    /// Count of gh_commit_pushed events that day.
    public let commitsCount: Int

    /// AI ratio 0.0..1.0 for the day; 0.0 if no attention in day.
    public let aiRatio: Double

    public static let empty = DailyMetric(
        dayStartMs: 0, focusedMin: 0, sessionsCount: 0, commitsCount: 0, aiRatio: 0
    )

    public init(
        dayStartMs: Int64, focusedMin: Int, sessionsCount: Int, commitsCount: Int, aiRatio: Double
    ) {
        self.dayStartMs = dayStartMs
        self.focusedMin = focusedMin
        self.sessionsCount = sessionsCount
        self.commitsCount = commitsCount
        self.aiRatio = aiRatio
    }
}
```

### 3.4 Streak event-source mapping

| Field | Source | Predicate per day (high-level — real query body in LeafCorePrivate moat) |
|---|---|---|
| `commitStreak` | `events` table (action stream) | `gh_commit_pushed` events landing inside the day window |
| `issueCloseStreak` | `events` table | `linear_status_transition` events with `transition_type=completed` inside the day window |
| `huddleStreak` | `events` table | `slack_huddle_state_change` events with `state=started` inside the day window |
| `focusSessionStreak` | derived via focus session aggregation (reuses `focusSessions(period:)` internal logic) | ≥1 session ≥10 min in [start, end) |
| `heavyPulseStreak` | `intensity_aggregates` table (M018) | At least one minute-bucket in [start, end) crossing the T4 "heavy" thresholds for keystrokes / mouse_moves / app_switches (constants in moat) |

All counts evaluated **per-day** then collapsed via `streakBackFromDay` helper:

```swift
/// Counts consecutive non-zero entries from the tail (most-recent day).
/// e.g., [0, 1, 0, 1, 1, 1, 1] → 4 (last 4 days all qualifying).
/// e.g., [1, 1, 0, 0, 0, 0, 0] → 0 (today=0 ends streak immediately).
internal func streakBackFromDay(eventCountPerDay: [Int]) -> Int {
    var streak = 0
    for count in eventCountPerDay.reversed() {
        guard count > 0 else { break }
        streak += 1
    }
    return streak
}
```

### 3.5 PeakHour computation

```swift
/// Aggregates attention-event minutes per local-TZ hour bucket across the 7-day window.
/// Returns hour 0..23 with maximum minutes, or nil if total attention < 5 min.
/// Tie-break: lowest hour wins.
internal func computePeakHour(weekStartMs: Int64, weekEndMs: Int64, db: Database) throws -> Int? {
    // Real query body lives in LeafCorePrivate moat.
    // Conceptually: bucket attention-event minutes by local-TZ hour-of-day
    // (0..23) inside [weekStartMs, weekEndMs), pick the bucket with the
    // largest total duration. Lowest hour wins on ties.
}
```

Tie-break determinism: deterministic — among hours sharing the maximum total duration, the lowest hour wins.

Threshold guard: aggregate total minutes < 5 → return nil.

### 3.6 WoW delta computation

```swift
internal func wowFormula(thisWeekFocused: Int, lastWeekFocused: Int) -> Double? {
    guard lastWeekFocused > 0 else { return nil }
    return Double(thisWeekFocused - lastWeekFocused) / Double(lastWeekFocused)
}
```

Last-week boundary: `dayBoundaries(now: calendar.date(byAdding: .day, value: -7, to: now)!, calendar:)` returns days[-7..-13] start/end pairs. Sum `fetchFocusedMin(start, end)` over those 7 pairs.

### 3.7 Day boundaries helper

```swift
/// Returns 7 (start, end) pairs anchored at local-TZ midnight, oldest → newest.
/// boundaries[0].start = startOfDay(now - 6d), boundaries[6].end = startOfDay(now + 1d).
internal func dayBoundaries(
    now: Date,
    calendar: Calendar = .current
) -> [(startMs: Int64, endMs: Int64)] {
    let today = calendar.startOfDay(for: now)
    var pairs: [(Int64, Int64)] = []
    for offset in (-6...0) {
        guard let start = calendar.date(byAdding: .day, value: offset, to: today),
              let end = calendar.date(byAdding: .day, value: offset + 1, to: today)
        else { continue }
        pairs.append((Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000)))
    }
    return pairs
}
```

### 3.8 Protocol method placement

В `DerivedInsights.swift` под существующим Track-9 T1 section:

```swift
// MARK: - Track-9 T1 — recent commit deriver

func recentLastCommit(maxAgeMs: Int64) throws -> RecentCommitSnapshot?

// MARK: - Track-9 T4 — weekly metrics deriver

/// Track-9 T4 — 7-day analytics aggregation anchored at local-TZ midnight.
/// Returns `dailySeries` (7 entries), peakHour, single-metric WoW delta, 5 streak counters.
/// `now: Date` for testability (period derives [today − 6d .. today]).
/// Default `.empty` for stubs / iOS-future.
func weeklyMetrics(now: Date) throws -> WeeklyMetrics
```

`extension DerivedInsights` default:
```swift
public func weeklyMetrics(now: Date) throws -> WeeklyMetrics { .empty }
```

`StubInsights` explicit override:
```swift
public func weeklyMetrics(now: Date) throws -> WeeklyMetrics { .empty }
```

---

## 4. Acceptance criteria

| # | Criterion | Verification |
|---|---|---|
| AC-1 | `WeeklyMetrics` public struct exists в `Packages/LeafCore/Sources/LeafCore/Insights/WeeklyMetrics.swift` с 8 полями + `.empty` static | `grep -nE "public struct WeeklyMetrics" Packages/LeafCore/Sources/LeafCore/Insights/WeeklyMetrics.swift` returns hit |
| AC-2 | `DailyMetric` public struct в том же файле, 5 полей + `.empty` static | `grep -nE "public struct DailyMetric" Packages/LeafCore/Sources/LeafCore/Insights/WeeklyMetrics.swift` returns hit |
| AC-3 | `DerivedInsights.weeklyMetrics(now:)` protocol method + extension default + StubInsights override | `grep -nE "func weeklyMetrics\(now:" Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift` returns 3 hits |
| AC-4 | LeafCorePrivate moat impl `ProdInsights+WeeklyMetrics.swift` exists, conforms к `DerivedInsights`, computes all fields | `test -f Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+WeeklyMetrics.swift` returns 0 |
| AC-5 | All public tests pass: WeeklyMetricsTests (Equatable + `.empty`), DailyMetricTests (Equatable), DerivedInsightsStub default test | `swift test --filter WeeklyMetricsTests` + `--filter DailyMetricTests` + Stub default test green |
| AC-6 | All moat tests pass: 7 scenarios в `ProdInsightsWeeklyMetricsTests` (happyPath / coldTick / weekOff / streakBreaks / peakHourTie / localTZBoundary / emptyDB) | `swift test --filter ProdInsightsWeeklyMetricsTests` green |
| AC-7 | 5/5 xcodebuild schemes Debug build SUCCESS | `for s in LeafCore LeafCorePrivate Leaf LeafAgent LeafMCP; do xcodebuild -scheme $s -configuration Debug build; done` все green |
| AC-8 | Net new test count = 12 (7 moat + 4 public + 1 stub — exact tally в §5) | Post-T4 SPM total = 2925 (T3 baseline 2913 + 12) |
| AC-9 | Zero new SQLCipher migrations | `git diff feature/track-9-substrate -- Packages/LeafCore/Sources/LeafCore/DB/` empty |
| AC-10 | Zero new MCP tools | `git diff feature/track-9-substrate -- LeafMCP/ Packages/LeafCore/Sources/LeafCore/MCP/` empty |
| AC-11 | Zero ShareEventTypeKey delta (registry frozen at 198) | `git diff feature/track-9-substrate -- Packages/LeafCore/Sources/LeafCore/Privacy/ShareEventTypeKey.swift` empty |
| AC-12 | Zero UI surface changes | `git diff feature/track-9-substrate -- Leaf/Views/` empty |
| AC-13 | Zero new event_kinds | `git grep -nE "case [a-z][A-Za-z]+ = \"[a-z_]+\"" Packages/LeafCore/Sources/LeafCore/Privacy/ -- "*EventKindKey*"` count unchanged vs T3 baseline |
| AC-14 | Privacy walkback narrow grep в T4 file scope → 0 hits | `git diff feature/track-9-substrate --name-only \| xargs grep -nE "absolute_path\|full_comment_body\|raw_email\|notes_body\|email_subject\|note_body\|file_contents\|raw_prompt\|tool_input\|tool_response\|response_body"` returns 0 hits |
| AC-15 | `just check-tokens` 3-tier clean | Run `just check-tokens`, exit 0 |
| AC-16 | DispatchCoverageTests parity fences unchanged (T4 не добавляет event_kinds) | `swift test --filter DispatchCoverageTests` green без bumps |
| AC-17 | Branch `feature/track-9-substrate` off T3 tip `3bb9f26a`, T4 commits stacked atop | `git log --oneline 3bb9f26a..HEAD` shows только T4 commits |
| AC-18 | Spec self-review clean (no TBD / TODO / placeholder, no contradicting decisions) | Manual pass before plan write |

---

## 5. Tests

### 5.1 Public tests (LeafCoreTests)

**`Packages/LeafCore/Tests/LeafCoreTests/Insights/WeeklyMetricsTests.swift`** (NEW):

| Test | Asserts |
|---|---|
| `testWeeklyMetricsEquatableRoundTrip` | Init + Equatable + identity invariant |
| `testWeeklyMetricsEmptyShape` | `.empty` returns 7 zero DailyMetric entries, all streaks=0, peakHour=nil, wowDelta=nil |
| `testDailyMetricEquatableRoundTrip` | Init + Equatable |
| `testDailyMetricEmptyShape` | `.empty` returns 0/0/0/0/0 zero-day |

**`Packages/LeafCore/Tests/LeafCoreTests/Insights/DerivedInsightsStubWeeklyMetricsTests.swift`** OR extend existing `DerivedInsightsStubTests`:

| Test | Asserts |
|---|---|
| `testWeeklyMetricsDefaultReturnsEmpty` | `StubInsights().weeklyMetrics(now: Date()) == .empty` |

Total **5 public tests**.

### 5.2 Moat tests (LeafCorePrivateTests)

**`Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsWeeklyMetricsTests.swift`** (NEW):

| Test | Fixture | Asserts |
|---|---|---|
| `testHappyPath_14DaysFull` | 14 days of dense events (commits / linear closes / huddle starts / focus sessions / heavy intensity / attention events distributed across hours) | Exact values for all WeeklyMetrics fields. peakHour matches injected peak. wowDelta computed correctly. All 5 streaks=7 (full week qualifying). |
| `testColdTick_FirstDay` | DB has 1 day of data (today only), 1 commit + 1 focus session + heavy intensity | dailySeries has 7 entries (6 empty + today populated). commitStreak=1, focusSessionStreak=1, heavyPulseStreak=1, issueCloseStreak=0, huddleStreak=0. peakHour=hour of single populated attention bucket OR nil if <5 min. wowDelta=nil (last week zero). |
| `testWeekOff_LastWeekZero` | This week has full events, last week has zero events | wowDelta=nil (last_week_focused == 0). This-week metrics populated. |
| `testStreakBreaks` | Commits on days [-6, -5, -4] but none on [-3, -2, -1, 0]. | commitStreak=0 (today ends streak immediately, max-from-tail semantic). Other streaks consistent with their day patterns. |
| `testPeakHourTie` | Two hours (e.g., 9 AM and 14 PM) have identical attention minutes | peakHour=9 (lowest hour wins tie-break determinism). |
| `testLocalTZBoundary` | Event at 23:55:00 local Sun + event at 00:05:00 local Mon — same physical date if UTC, different days local | dailySeries[5] (Sun) and dailySeries[6] (Mon) both populated with respective events. Day count differentiation confirms local TZ anchoring. |
| `testEmptyDB` | No events at all | Returns `.empty`-shaped result (all 7 dailySeries entries default, all streaks=0, peakHour=nil, wowDelta=nil). dayStartMs values still populated correctly per `now`. |

Total **7 moat tests**.

### 5.3 Total test delta

| Surface | New tests |
|---|---|
| LeafCoreTests (public) | 5 |
| LeafCorePrivateTests (moat) | 7 |
| **Total** | **12 net new tests** |

T3 baseline = 2913 (2868 XCTest + 45 Swift-Testing). Post-T4 expectation: **2925 total** (12 added, 0 removed).

### 5.4 No sentinel-injection

T4 deriver reads only aggregated counts / durations / timestamps / intensity buckets — **no body fields, no excerpts, no titles, no URLs**. Mirror Track-8 P3/P4/P5/P7 + Track-9 T1 precedent (no sentinel test).

Privacy walkback (AC-14) — single grep pass against T4 file scope:
```
grep -nE "absolute_path|full_comment_body|raw_email|notes_body|email_subject|note_body|file_contents|raw_prompt|tool_input|tool_response|response_body" \
  Packages/LeafCore/Sources/LeafCore/Insights/WeeklyMetrics.swift \
  Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift \
  Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+WeeklyMetrics.swift
```
Expected 0 hits.

---

## 6. Files touched

| File | Change | Approx LOC |
|---|---|---|
| `Packages/LeafCore/Sources/LeafCore/Insights/WeeklyMetrics.swift` | NEW — WeeklyMetrics + DailyMetric structs | ~80 |
| `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift` | MODIFIED — +1 protocol method + extension default + StubInsights override | +10 |
| `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+WeeklyMetrics.swift` | NEW (gitignored moat) — ProdInsights conformance + 3 internal helpers + SQL | ~200 |
| `Packages/LeafCore/Tests/LeafCoreTests/Insights/WeeklyMetricsTests.swift` | NEW — 4 Equatable / `.empty` tests | ~80 |
| `Packages/LeafCore/Tests/LeafCoreTests/Insights/DerivedInsightsStubWeeklyMetricsTests.swift` | NEW (или extend existing DerivedInsightsStubTests) | ~30 |
| `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsWeeklyMetricsTests.swift` | NEW (gitignored moat) — 7 scenario tests w/ fixture seeding | ~400 |

**Public-only LOC delta:** ~200. **Moat LOC delta:** ~600 (impl + tests).

**Zero touches:**
- `Packages/LeafCore/Sources/LeafCore/DB/` (no migrations)
- `Packages/LeafCore/Sources/LeafCore/Privacy/ShareEventTypeKey.swift` (registry frozen)
- `LeafMCP/` (no new tools)
- `Leaf/Views/` (UI unchanged)
- `Leaf/Models/InsightsReader.swift` (T9 wires consumption)
- `Leaf/Models/InsightsSnapshot.swift` (T9 adds defaulted field)
- `LeafAgent/` (collector unchanged)

---

## 7. Out of scope (carry list)

| Carry | Target phase | Notes |
|---|---|---|
| `topTools: [SurfacePill]` week-scoped field | T6 | Q1 decision. T6 owns SurfacePill discriminator refactor — coupling cost > value. T6 либо defaulted-init field-extension, либо `weekTopSurfaces(now:)` parallel deriver. |
| Multi-metric WoW deltas (`wowDeltas: WoWDeltas` struct) | T9 OR post-T9 if UI asks | YAGNI до master spec §T9 mockup explicit ask. |
| Per-day surface breakdown (`DailyMetric.surfaceBreakdown`) | T9 OR post-T9 if UI asks | YAGNI. |
| Variable-period signature (`weeklyMetrics(period:)` / `monthlyMetrics(now:)`) | Post-Track-9 if 30d/90d asked | T9 mockup статичный 7-day. Future parallel method, не rename. |
| `InsightsReader.refresh()` fetch wiring | T9 | T9 scope (UI consumer phase). |
| `InsightsSnapshot.weeklyMetrics` defaulted field | T9 | Same. |
| `AnalyticsView.swift` real content (chart + cards) | T9 | Master spec §T9 explicit. |
| `InsightsSnapshot.recentActivity` orphan drop (Track-8 P9 C-24) | T10 wrap | Не T4 scope. |
| `get_weekly_metrics` MCP tool | Post-Track-9 | Если ask будет. Master spec §10 carry. |
| Master spec §T4 amendment (8-day wording → 7-day; topTools dropped) | T10 wrap | T4 spec is authoritative implementation contract; master spec amendment в T10. |

---

## 8. Branch + commit decomposition (preview)

Plan written в `.claude/plans/track-9-T4.md` (gitignored) decomposes в ~5-6 atomic commits:

1. **feat(track-9-T4):** WeeklyMetrics + DailyMetric value types (+5 public tests)
2. **feat(track-9-T4):** DerivedInsights.weeklyMetrics protocol method + default + StubInsights override (+1 stub test)
3. **feat(track-9-T4) [moat]:** ProdInsights+WeeklyMetrics impl + internal helpers
4. **test(track-9-T4) [moat]:** 7 scenario tests w/ fixture seeding
5. **chore(track-9-T4):** spec landing (this file) + plan link

Public commits land на `feature/track-9-substrate`; moat files в LeafCorePrivate gitignored worktree (cp into checkout перед merge per Track-9 T1 precedent).

---

## 9. Open questions

None — all Stage 2 brainstorm questions resolved (Q1-Q6 в §2 decisions table).

---

## 10. Master spec §T4 amendment plan (T10 wrap)

Когда T10 wrap soundez, master spec §T4 line 172-176 amend:

- "8 × `TodayMetrics` daily aggregation" → "7-day dailySeries; T9 composes 8th today-chip via existing `todayMetrics(now:)`".
- "week-scoped top tools (reuses T6 family-grouped aggregation)" → REMOVE entirely (T6 owns).
- Net deltas amended (zero new event_kinds / migrations / MCP tools / registry; +1 protocol method).
