# Track-9 T6 — TODAY hybrid pills + 5th cell + InsightsReader.State.error retention

**Phase**: Track-9 T6  
**Status**: SPEC  
**Branch**: `feature/track-9-substrate` (off T5 tip `5c11e5a2`)  
**Predecessors**: T1..T5 (substrate enrichment + YOU·NOW depth)  
**Master spec**: `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md` §3.2 / §T6 / §9.1 (C-1 / C-2 / C-3)  
**Carry resolutions**: master spec §9.1 — **C-1 RESOLVED T6** (hybrid pills) / **C-2 RESOLVED T6** (error retention) / **C-3 RESOLVED T6** (5-cell wide + 2×3 narrow grid)  
**Substrate purity**: zero new SQLCipher migrations / event_kinds / MCP tools. ShareEventTypeKey registry frozen at **198** post-T3.

---

## §1 Scope

T6 closes three carries from Phase 8.9 P9 master spec §9.1 in a single phase:

1. **C-1 hybrid pills** — `SurfacePill` discriminator `.captureTime | .actionNoun` + family-grouped substrate refactor (13 families per master spec scope lock #6). Capture surfaces render attention-time ("Claude 1h 23m"), Layer B providers render action-noun counts ("Linear 3").
2. **C-3 5-cell metricsRow** — `TodayMetrics.switchCount` (substrate-ready since Phase 8.3, unrendered through Phase 8.9 P9) promoted to UI. `ViewThatFits` rebalance: wide 5-cell HStack / narrow 2-col × 3-row `Grid` (5 cells fill top-left → bottom-middle, bottom-right empty).
3. **C-2 InsightsReader.State.error retention** — associated value `lastKnown: InsightsSnapshot?` added; `refresh()` captures previous `.loaded` snapshot before throwing transition; `HomeView` `.error` branch renders banner + `HomeContent(snapshot: lastKnown)` gracefully when lastKnown non-nil. Phase 8.3 spec MS-5 contract closed.

### §1.1 Hard exclusion (out of scope)

- **No new event_kinds.** T6 reads existing substrate (`timeInApp` output + existing `events` rows for Layer B counts + existing meeting state events).
- **No new SQLCipher tables / migrations.** Registry frozen at 198. M001-M018 + M024 + M026 + M027 preserved.
- **No new MCP tools.** `get_today_metrics` not added — TODAY is UI-block-scoped, Layer B MCP tools already cover provider activity.
- **No new ShareEventTypeKey entries.** Reads aggregate counts and durations from already-shared event types.
- **No mockup §3 line-3 surface enrichment.** YOU·NOW depth (intensity bars / branch / linearID) shipped T5; T6 is TODAY-block only.
- **No Analytics surface change.** Track-9 T9 owns post-T4 `WeeklyMetrics` UI consumption.
- **No `share_event_types` runtime persistence.** Deferred to Phase 5.4 per Track-4 S4 carry.
- **No bundle-ID list in public LeafCore.** Family bundle-ID composition lives in **LeafCorePrivate moat** per pre-push-leaf checklist (CLAUDE.md "Share Controls preset bundle IDs" = implementation moat).
- **No GitHub `gh_pr_closed` semantic** for action-noun. Only `gh_pr_merged` (shipped today) counts — closed-unmerged not a "you shipped X" hero metric.

### §1.2 Deviations from master spec

None. T6 implements §3.2 / §T6 contract literally. Mixed-unit pill sort (open in master spec) resolved with **balance-by-kind** policy (§4.2 below).

---

## §2 Substrate touches summary

| Layer | File | Touch |
|-------|------|-------|
| LeafCore types | `Packages/LeafCore/Sources/LeafCore/Home/SurfacePill.swift` | NEW `SurfacePillKind` enum + add `kind: SurfacePillKind` field to `SurfacePill` (NO default — explicit at both call sites) |
| LeafCore types | `Packages/LeafCore/Sources/LeafCore/Home/PillFamily.swift` | NEW enum `PillFamily` (13 cases) + `displayName` + `kind: SurfacePillKind` per family |
| LeafCore types | `Packages/LeafCore/Sources/LeafCore/Home/SurfacePillRouter.swift` | EXTEND existing `SurfacePillRouter.route(forPillID:)` — no signature change; body picks up new `PillFamily.rawValue` IDs (capture families → `.homeSurface` when HomeSurface match exists, Layer B providers → `.layerBProvider`, Track-4 S2 families Mail/Notes/Music/Reminders → nil → non-tappable pill) |
| LeafCore types | `Packages/LeafCore/Sources/LeafCore/Insights/InsightsReader.State` (via `Leaf/Models/InsightsReader.swift`) | `.error(message:lastKnown:)` associated value added |
| LeafCore moat | `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Insights/ProdTodayPillFamilyMap.swift` | NEW static map `PillFamily → Set<String>` bundle IDs (capture families) + per-family display name override if differs from enum |
| LeafCore moat | `Packages/LeafCorePrivate/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+TodayMetrics.swift` | Refactor `queryPills()` — replace prefix-LIKE per-surface aggregation with family-aware path branch (`timeInApp` aggregation for `.captureTime`; new private helpers per provider for `.actionNoun`); add `queryMeetingTimeSec` (Calendar family); add `queryPRsMergedCount` / `queryLinearIssuesCompletedCount` / `querySlackMessagesAuthoredCount`; apply balance-by-kind cap-8 sort |
| App | `Leaf/Models/InsightsReader.swift` | `State.error` cases updated; `refresh()` captures `previousLoaded` pre-transition |
| App | `Leaf/Views/Window/Home/HomeView.swift` | `.error` branch: `lastKnown == nil` → existing full-page banner / non-nil → banner + `HomeContent(snapshot: lastKnown)` |
| App | `Leaf/Views/Window/Home/TodayBlock.swift` | `metricsRow` wide branch → 5-cell HStack (switches inserted between sessions and commits); narrow branch → `Grid` 2-col × 3-row; pill renderer switches on `pill.kind` for label formatting |

**Public API additions (LeafCore)**:

- `SurfacePillKind` enum (`captureTime` / `actionNoun`)
- `PillFamily` enum (13 cases) + `displayName` + `kind` per family
- `SurfacePill.kind: SurfacePillKind` field (no default)
- `SurfacePillRouter.route(forPillID:)` extended (no signature change) — picks up `PillFamily.rawValue` IDs

**No public API removals.** `HomeSurface` enum unchanged.

---

## §3 SQL refactor — capture-surface attention-time + Layer B counts

### §3.1 Capture-family aggregation path (reuses `timeInApp`)

Six capture families plus Calendar use `DerivedInsights.timeInApp(period:)` output (already fetched in `InsightsReader.refresh()` at line 91 — no additional SQL):

- **Claude** — bundle IDs in moat (`com.anthropic.claudefordesktop` + Claude Code CLI surface bundle if foreground-detectable)
- **Xcode** — `com.apple.dt.Xcode`
- **IDEs** — VSCode-family bundles + JetBrains bundles (moat lists from Track-6 P6 IDEs storage gates)
- **Browsers** — Safari + Chrome + Arc bundles (moat list from Track-6 P3 browser allow-list)
- **Zoom** — `us.zoom.xos`
- **Mail / Notes / Music / Reminders** — Track-4 S2 bundles (`com.apple.mail`, `com.apple.Notes`, `com.apple.Music`, `com.apple.reminders`)

**Aggregation**: for each family `f`, the per-family total seconds is the sum of `entry.duration` over `timeInAppOutput` entries whose bundleID falls within `familyBundles[f]`. Emit pill `SurfacePill(id: f.rawValue, label: f.displayName, count: Int(seconds[f]), kind: .captureTime)` when `seconds[f] > 0`.

**Accepted minor inefficiency**: `timeInApp(period:)` is already called by `InsightsReader.refresh()` line 91 for `topApps` snapshot field; T6 calls it again inside `todayMetrics(now:)` for pill aggregation — two SQL roundtrips for the same data per refresh. YAGNI vs signature change to thread cached output into `todayMetrics()`. Acceptable until profiling shows hotspot; revisit if `refresh()` exceeds 200ms p95.

### §3.2 Calendar pill (`.captureTime` from meeting state pairs)

NEW private helper `queryMeetingTimeSec(startMs:endMs:)` in `ProdInsights+TodayMetrics.swift`:

```
Semantic (real query body in LeafCorePrivate moat):
  Total clipped meeting seconds within [periodStart, periodEnd].
  Inputs: meeting_state_entered + meeting_state_exited events from the
  expanded window [periodStart - 24h, periodEnd] (to catch pairs that
  straddle the boundary). Pair each enter with the next exit in temporal
  order; clip the resulting interval to [periodStart, periodEnd]; drop
  pairs that fall entirely outside the period; an unmatched dangling
  enter (open meeting) is closed at periodEnd.
```

Implementation: fetch all `meeting_state_*` events in the expanded window, walk in temporal order, accumulate clipped durations. Pure Swift pass after the read — no complex windowing required (Track-4 S1 substrate emits these). Cold-start before any meetings → returns 0 → no Calendar pill emitted.

Calendar pill emit: `SurfacePill(id: "calendar", label: "Calendar", count: clippedTotalSec, kind: .captureTime)` when > 0.

### §3.3 Layer B action-noun helpers (3 new private SQL functions)

Each returns `Int` row count, scoped to local-TZ today window via `todayInterval()` (existing helper, reused).

```
Semantics (real query bodies live in LeafCorePrivate moat — each returns a row count in [startMs, endMs)):

queryLinearIssuesCompletedCount(startMs:endMs:):
  Count of events whose source is 'linear' + event_kind 'status_transition'
  + to_state_type 'completed' inside the today window.

queryPRsMergedCount(startMs:endMs:):
  Count of `gh_pr_merged` events inside the today window.

querySlackMessagesAuthoredCount(startMs:endMs:):
  Count of `slack_message_authored_aggregate` events inside the today window.
```

Emit pattern (for each provider with count > 0):
- `SurfacePill(id: "linear", label: "Linear", count: linearCount, kind: .actionNoun)`
- `SurfacePill(id: "github", label: "GitHub", count: prsMergedCount, kind: .actionNoun)`
- `SurfacePill(id: "slack", label: "Slack", count: slackCount, kind: .actionNoun)`

**Semantic anchors** (locked at spec, exact event_kind names verified via grep at impl time):

- **Linear "issues completed today (you)"** — `status_transition` with `to_state_type='completed'`. Phase 4.6.B viewer-actor filter already client-side-applied at collector; events table only contains viewer-authored transitions.
- **GitHub "PRs merged today"** — `gh_pr_merged` (distinct from `gh_commit_pushed` which already powers `commits` metricsRow cell — explicit semantic split avoids redundant hero-data).
- **Slack "messages authored today"** — `slack_message_authored_aggregate` row count (Phase 4.6.A.3 baseline).

### §3.4 Balance-by-kind cap-8 sort (master spec gap resolution)

Master spec §3.2 specifies `surfacePillCap = 8` but leaves sort policy unstated. Mixed-unit sort by raw `count` would have `.captureTime` (seconds) dominate `.actionNoun` numerically — Layer B pills evicted whenever any capture activity present.

**Resolution**: within-kind sort + top-K-per-kind merge.

```
let captureTopK = capturePills.sorted { $0.count > $1.count }.prefix(5)
let actionNounTopK = actionNounPills.sorted { $0.count > $1.count }.prefix(3)
return Array(captureTopK) + Array(actionNounTopK)    // total ≤ 8
```

Ordering invariant: capture pills first (longest-time hero), action-noun second (Layer B tail). When one kind has < K available, do NOT backfill from other kind — under-cap is acceptable and predictable.

UI sort order at emit time stable; `TodayBlock.pillStrip` renders in iteration order.

### §3.5 No presence_state writes

T6 reads `events` table + existing `timeInApp` aggregate. **Zero writes to `presence_state`**. No new sentinel-injection test needed (no payload field reads carry forbidden body content).

---

## §4 UI changes (SurfacePill kind + LeafPill formatter + 5-cell metricsRow + ViewThatFits 2×3)

### §4.1 SurfacePill kind renderer

`TodayBlock.swift` pillStrip pill-button extension:

```swift
private func pillLabel(_ pill: SurfacePill) -> String {
    let suffix: String
    switch pill.kind {
    case .captureTime:
        suffix = formatDurationCompact(seconds: pill.count)
    case .actionNoun:
        suffix = "\(pill.count)"
    }
    return "\(pill.label) \(suffix)"
}

private func formatDurationCompact(seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m" }
    return "<1m"   // never zero by emit invariant (count > 0)
}
```

`<1m` floor: when family has any activity but < 60 sec total, still emit (master spec spirit — show signal not silence) but normalize display. Alternative "Xs" considered then dropped — TODAY block is daily-coarse, sub-minute irrelevant.

### §4.2 TodayBlock 5-cell metricsRow + ViewThatFits 2×3

Wide branch — extend current 4-cell HStack:

```
HStack(alignment: .top, spacing: LeafSpace.lg) {
    metricCell(value: focusValue,    label: "focused")
    metricCell(value: aiRatioValue,  label: "AI ratio")
    metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
    metricCell(value: "\(metrics.switchCount)",  label: "switches")    // NEW
    metricCell(value: "\(metrics.commitsCount)", label: "commits")
    Spacer()
}
```

Narrow branch — replace existing 2×2 VStack with `Grid` 2-col × 3-row row-major (SwiftUI 4+ `Grid`):

```
Grid(alignment: .topLeading, horizontalSpacing: LeafSpace.lg, verticalSpacing: LeafSpace.md) {
    GridRow {
        metricCell(value: focusValue,    label: "focused")
        metricCell(value: aiRatioValue,  label: "AI ratio")
    }
    GridRow {
        metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
        metricCell(value: "\(metrics.switchCount)",  label: "switches")
    }
    GridRow {
        metricCell(value: "\(metrics.commitsCount)", label: "commits")
        Color.clear.frame(width: 1, height: 1)    // bottom-right intentional gap
    }
}
```

Reading order top-left → right → next row. Empty bottom-right cell acceptable per master spec §3.2 "2×3 / 3×2" (either is conforming; row-major reading more natural for left-to-right languages).

### §4.3 SurfacePillRouter routing extension

`SurfacePillRouter.route(forPillID:)` keeps signature, body extended:

```swift
public static func route(forPillID id: String) -> SurfacePillRoute? {
    // Existing HomeSurface + LayerBProvider matches
    if let surface = HomeSurface(rawValue: id) { return .homeSurface(surface) }
    if let provider = LayerBProvider(rawValue: id) { return .layerBProvider(provider) }
    // PillFamily.* IDs that don't match HomeSurface/LayerBProvider → nil → non-tappable
    return nil
}
```

`PillFamily.rawValue` matches `HomeSurface.rawValue` for the 6 capture surfaces (Claude/Xcode/IDEs/Browsers/Zoom/Calendar) and `LayerBProvider.rawValue` for the 3 providers (Linear/GitHub/Slack). The 4 Track-4 S2 families (Mail/Notes/Music/Reminders) emit IDs that match neither → `nil` route → non-tappable pill (existing precedent at TodayBlock pill-button gate).

### §4.4 Accessibility

Per Phase 8.9 P9 sweep pattern — each new cell gets `.accessibilityElement(children: .ignore)` + `.accessibilityLabel("\(value) \(label)")`. New "switches" cell: `accessibilityLabel("\(metrics.switchCount) switches")`. Empty `Color.clear` placeholder in narrow grid: `.accessibilityHidden(true)`.

---

## §5 InsightsReader.State.error retention pattern (C-2)

### §5.1 State enum signature change

```swift
// BEFORE
case error(message: String)

// AFTER  
case error(message: String, lastKnown: InsightsSnapshot?)
```

### §5.2 refresh() race-safe capture

```swift
func refresh() {
    // C-2: capture previous loaded snapshot BEFORE any state transition.
    // Local-scope variable — race-safe vs detached Task → catch reading self.state
    // after self.state already changed.
    let previousLoaded: InsightsSnapshot? = {
        if case .loaded(let snap, _) = self.state { return snap }
        return nil
    }()

    self.state = .loading

    Task.detached(priority: .userInitiated) { [insights, database, dbFileURL] in
        do {
            // ... 19 sequential SQL fetches unchanged ...
            await MainActor.run {
                self.state = .loaded(snapshot: snapshot, updated: Date())
            }
        } catch {
            await MainActor.run {
                self.state = .error(
                    message: "Couldn't read today's activity. Try Refresh.",
                    lastKnown: previousLoaded
                )
            }
        }
    }
}
```

`previousLoaded` is local to `refresh()` invocation — if user triggers retry while in-flight, each refresh captures its own snapshot independently.

### §5.3 HomeView .error branch — partial render

```swift
switch reader.state {
case .loading:
    LoadingScaffold()
case .notConfigured(let msg):
    notConfiguredFullPage(msg)
case .empty(let msg):
    emptyFullPage(msg)
case .error(let msg, let lastKnown):
    if let snapshot = lastKnown {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            errorBanner(msg)            // existing banner, kept above content
            HomeContent(snapshot: snapshot)
        }
    } else {
        errorBanner(msg)                // cold-error UX preserved
    }
case .loaded(let snapshot, _):
    HomeContent(snapshot: snapshot)
}
```

Phase 8.3 MS-5 contract honored: "banner above metrics, last-known TODAY values still render". All five blocks (TODAY / YOU·NOW / WITH YOU ON THIS / INBOX / WHERE STOPPED) consume `lastKnown` snapshot — they don't know data is stale beyond what the banner communicates. Acceptable single-cycle staleness; banner CTA "Try again" triggers fresh fetch.

### §5.4 Banner-only UX preserved for cold-error

If `lastKnown == nil` (first refresh fails before any successful load), behavior identical to pre-T6 — full-page `LeafBanner.danger`. No regression for cold-error path.

---

## §6 Testing

### §6.1 Public LeafCore tests

`SurfacePillTests.swift` (`Packages/LeafCore/Tests/LeafCoreTests/Home/SurfacePillTests.swift`):

- **T1** `surfacePill_captureTime_initializesWithSeconds` — `SurfacePill(id:"claude", label:"Claude", count: 4860, kind: .captureTime)` round-trips through Equatable / Hashable / Sendable conformances.
- **T2** `surfacePill_actionNoun_initializesWithCount` — `SurfacePill(id:"linear", label:"Linear", count: 3, kind: .actionNoun)` round-trips.
- **T3** `surfacePill_kindDiscriminator_distinguishesEquality` — two pills with same `id/label/count` but different `kind` are NOT equal.

`PillFamilyTests.swift`:

- **T4** `pillFamily_allCases_count_equals_13` — guard regression against silent enum drift.
- **T5** `pillFamily_kindMapping_captureFamiliesAreCaptureTime` — 10 capture families (Claude/Xcode/IDEs/Browsers/Zoom/Calendar/Mail/Notes/Music/Reminders) all map to `.captureTime`.
- **T6** `pillFamily_kindMapping_layerBProvidersAreActionNoun` — Linear/GitHub/Slack map to `.actionNoun`.

`SurfacePillRouterTests.swift` (extend existing):

- **T7** `router_captureSurface_routesToHomeSurface` — capture pill IDs matching `HomeSurface` resolve.
- **T8** `router_layerBProvider_routesToLayerB` — `linear`/`github`/`slack` IDs resolve to `.layerBProvider`.
- **T9** `router_track4S2Families_returnNil` — Mail/Notes/Music/Reminders IDs return nil (non-tappable).
- **T10** `router_unknownID_returnsNil` — defensive default.

`InsightsSnapshotTests.swift` (extend existing):

- **T11** `insightsSnapshot_todayMetrics_defaulted_field_roundtrip` — confirm Phase 8.3 default `.empty` still works (no regression from T6 field additions).
- *(no new InsightsSnapshot field — T6 reuses existing `todayMetrics: TodayMetrics`)*

### §6.2 Moat tests (LeafCorePrivate, gitignored, local-machine-verified)

`ProdTodayPillFamilyMapTests.swift`:

- **T12** `familyMap_eachFamily_hasAtLeastOneBundleID` — coverage assertion.
- **T13** `familyMap_bundleIDsAreLowercase` — convention check.
- **T14** `familyMap_noBundleIDOverlap` — Mail bundles don't appear in Music family etc.

`ProdInsightsTodayMetricsTests.swift` (extend existing):

- **T15** `queryPills_captureFamily_aggregatesTimeInAppByBundle` — synthetic `timeInApp` returning 3 Xcode entries + 2 Cursor entries → emits one Xcode pill (seconds = sum) + one IDEs pill (seconds = sum).
- **T16** `queryPills_emptyTimeInApp_emitsNoPills` — cold-tick degenerate.
- **T17** `queryMeetingTimeSec_pairScan_clipsCorrectly` — meeting straddling period boundary → clipped duration.
- **T18** `queryMeetingTimeSec_unmatchedDangling_usesPeriodEnd` — open meeting (no exit event) treated as ongoing.
- **T19** `queryPRsMergedCount_matchesEventKindExactly` — only `gh_pr_merged`, not `gh_pr_opened` / `gh_pr_closed`.
- **T20** `queryLinearIssuesCompletedCount_filtersByActorAndTransitionType` — only `status_transition` with `to_state_type='completed'`.
- **T21** `querySlackMessagesAuthoredCount_aggregateOnly` — only `slack_message_authored_aggregate`.
- **T22** `queryPills_balanceCap_5capture_3actionNoun` — synthetic 8 capture families with non-zero time + 4 Layer B providers → emits top 5 capture + top 3 action-noun = 8 total, no backfill.
- **T23** `queryPills_underCap_layerBStillPreserved` — 2 capture families + 3 Layer B → emits 2 + 3 = 5 (no padding).
- **T24** `queryPills_within_kindSortDescByCount` — pills sorted within their kind groups.

### §6.3 InsightsReader state tests

`InsightsReaderStateTests.swift` (`Leaf/Tests/InsightsReaderStateTests.swift` or wherever Leaf target tests live):

- **T25** `reader_errorFromLoaded_capturesLastKnown` — pre-condition `.loaded(snap, _)`, force fetch throw, post-condition `.error(_, lastKnown: snap)`.
- **T26** `reader_errorFromColdStart_lastKnownIsNil` — pre-condition `.loading` (no prior load), force throw, post-condition `.error(_, lastKnown: nil)`.
- **T27** `reader_loadedErrorLoadedCycle_preservesContinuity` — `.loaded(A)` → refresh throws → `.error(_, A)` → refresh succeeds → `.loaded(B)` (clean transition).
- **T28** `reader_errorErrorCycle_keepsOriginalLastKnown` — `.loaded(A)` → throw → `.error(_, A)` → refresh throws again — `previousLoaded` captured at second refresh start is `nil` (state was `.error`, not `.loaded`), so result is `.error(_, nil)`. **Acceptable behavior** documented — last-known clears after first failed retry. Alternative ("sticky" retention through error chains) considered then rejected — adds complexity for marginal UX gain; user already saw stale data once.

### §6.4 No sentinel-injection regression test (explicit exemption)

T6 reads aggregate counts and durations from `events.payload_json` allowlisted fields (`event_kind`, `source`, `to_state_type`, timestamp). **No body / title / preview / content fields read.** Pattern parity with Track-9 T4 (`WeeklyMetrics` — same exemption, count/duration aggregates only). Spec §5.4 of T4 documented same; T6 inherits.

Cross-link: `Packages/LeafCore/Tests/LeafCoreTests/Insights/WeeklyMetricsTests.swift` header comment.

### §6.5 Test count delta

- LeafCore public: +11 tests (T1-T11)
- LeafCorePrivate moat: +13 tests (T12-T24)
- Leaf target: +4 tests (T25-T28)
- **Total: +28 net new tests** vs T5 baseline 2948 → target **≈ 2976 SPM tests** post-T6.

---

## §7 Acceptance gates (Stage 7 verification)

**AC-1** All 5/5 xcodebuild schemes Debug build SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).

**AC-2** SPM tests: ≥ 2976 total, 0 failures, ≤ 4 skipped (T5 baseline preserved).

**AC-3** `just check-tokens` 3-tier clean (BASE+MIGRATION+RETIRED).

**AC-4** Substrate purity: `git diff feature/track-9-substrate~N..HEAD -- Packages/LeafCore/Sources/LeafCore/DB/` empty (no new SQLCipher migrations).

**AC-5** Registry frozen: `git diff feature/track-9-substrate~N..HEAD -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` empty.

**AC-6** No new MCP tools: `git diff feature/track-9-substrate~N..HEAD -- LeafMCP/` empty.

**AC-7** Privacy walkback narrow grep on T6 file scope — 0 hits forbidden fields:
```
grep -nE "absolute_path|full_comment_body|raw_email|notes_body|prompt|tool_input|tool_response|response_body|email_subject|note_body|file_contents" \
  Packages/LeafCore/Sources/LeafCore/Home/SurfacePill.swift \
  Packages/LeafCore/Sources/LeafCore/Home/PillFamily.swift \
  Packages/LeafCore/Sources/LeafCore/Home/SurfacePillRouter.swift \
  Leaf/Models/InsightsReader.swift \
  Leaf/Views/Window/Home/HomeView.swift \
  Leaf/Views/Window/Home/TodayBlock.swift
# Expected: 0 hits
```

**AC-8** TodayBlock.swift LOC ≤ 280 (P9 budget preserved). Estimated post-T6 ≈ 215.

**AC-9** Master spec §9.1 inline status markers updated: C-1 / C-2 / C-3 each annotated `[RESOLVED T6 — commit <sha>]`.

**AC-10** Manual UI smoke (deferred to Track-9 wrap session per T1-T5 precedent; not blocking per-phase ship). Smoke list:
- TODAY card renders 5-cell wide layout when window is wide enough for wide HStack intrinsic size
- TODAY card switches to 2-col × 3-row `Grid` when window narrowed below wide branch's intrinsic minimum (cutoff intrinsic to `ViewThatFits` — no hardcoded threshold; verify experimentally by dragging window edge)
- Capture-time pill renders "Claude 1h 23m" / "Xcode 47m" — duration format
- Action-noun pill renders "Linear 3" / "GitHub 1" — discrete count
- Force `InsightsReader.refresh()` failure (kill DB connection mid-flight) → banner + TODAY card with last-known cells/pills rendered above other blocks
- Cold-error (delete DB then launch) → banner-only UX preserved

**AC-11** No `share_event_types` runtime persistence regression (Phase 5.4 carry preserved).

---

## §8 Master spec §9.1 carry-over status markers

T6 ship commit message includes inline annotation block for master spec amendment:

```
docs(track-9-T6): SHIPPED — master spec §9.1 status markers

C-1 hybrid pills (SurfacePill.kind discriminator + family-grouped substrate)
  → [RESOLVED T6 — commit <C1-sha>]
C-2 InsightsReader.State.error retention (Phase 8.3 MS-5 contract closed)
  → [RESOLVED T6 — commit <C2-sha>]
C-3 ViewThatFits 5-cell wide + 2×3 narrow grid
  → [RESOLVED T6 — commit <C3-sha>]
```

Per Phase 8.9 P9 precedent (`docs/superpowers/specs/2026-05-19-phase-8-9-polish.md` §9.1 lines 95-107), markers are inline at the carry text, not at the section header. Update done at Stage 8 (Ship) before final commit.

---

## §9 Out of scope / hard exclusion (formal contract anchor)

T6 **does not** add / change / touch:

- **Event_kinds** — registry frozen at 198. Existing kinds consumed only.
- **SQLCipher tables / migrations** — M001-M018 + M024 + M026 + M027 preserved (30 tables).
- **MCP tools** — 15-tool inventory unchanged.
- **ShareEventTypeKey** — registry frozen; no new entries.
- **`presence_state` writes** — T6 is read-only.
- **YOU·NOW depth** — T5 closed all main goal substrate gaps for `.active` mockup row 2-3.
- **WeeklyMetrics consumption** — T9 owns Analytics surface.
- **Mockup §3 line 3 surface enrichment** — captured intensity bars wired T5.
- **GitHub `gh_pr_closed` semantic** — closed-unmerged is not a "you shipped X" hero.
- **GitHub `gh_pr_opened` count** — opening a PR doesn't equal shipping; reserved for v1.1+ engagement metrics if requested.
- **Slack DM bucket counts** — substrate absent (Track-9 master spec §1.1, T2 verify confirmed negative).
- **AI narrative generation** — v1.1 BYO API key track.
- **Localization / i18n** — Track-9 carries this (master spec §9.1 C-19, Track-4 S2/S3 carry too).
- **Phase 5.6 dependencies** — relay status plumbing unaffected.
- **TodayBlock pill expand state restoration** — `pillsExpanded: @State` per-session only (carry to Track-9 if requested).

---

## §10 Open implementation calls (resolved at spec gate, locked for plan)

| # | Decision | Locked call |
|---|----------|-------------|
| A | GitHub action-noun semantic | "PRs merged today" = `gh_pr_merged` count |
| B | Narrow grid layout | `Grid` 2 cols × 3 rows row-major, bottom-right `Color.clear` placeholder |
| C | Family namespace | NEW `PillFamily` enum 13 cases in LeafCore.Home; routing via EXISTING `SurfacePillRouter.route(forPillID:)` extended (no signature change) |
| D | Slack action-noun semantic | "Messages authored today" = `slack_message_authored_aggregate` count |
| E | Linear action-noun semantic | "Issues completed today (you)" = `status_transition` with `to_state_type='completed'` |
| F | SurfacePill.kind default | NO default — explicit at all call sites (2 prod + 1 test fixture) |
| G | Mixed-unit pill sort | Balance: top 5 `.captureTime` + top 3 `.actionNoun` = 8 max, no backfill across kinds |
| H | Calendar pill semantic | `.captureTime` = `meeting_state_entered/_exited` pair-scan duration today |
| I | Error retention atomicity | Local-scope `previousLoaded` captured pre-`.loading` transition |
| J | Sub-minute capture display | `<1m` floor (alternative "Xs" rejected — TODAY is daily-coarse) |
| K | `.error → .error` cycle behavior | last-known clears after first failed retry (sticky retention not added — YAGNI) |
| L | TodayBlock pill formatter location | Inline private helper in TodayBlock.swift (alternative: extract to LeafCore module — deferred until 2nd consumer emerges) |

All 12 implementation calls locked at this spec. Plan (Stage 4) consumes these; implementation (Stage 5) executes literally.

---

## §11 Phase summary

T6 closes Track-9 TODAY-block scope completely:

- **C-1 hybrid pills** — 13-family substrate refactor, `.captureTime`/`.actionNoun` discriminator, balance-by-kind cap-8 sort
- **C-2 error retention** — `InsightsReader.State.error(message:, lastKnown:)` + `HomeView` partial render
- **C-3 5-cell metricsRow** — `switchCount` surfaced, ViewThatFits wide/narrow rebalance

Zero substrate (registry / migrations / event_kinds / MCP tools) — pure UI + moat SQL refactor. Builds on T1-T5 patterns: defaulted-init backward-compat where applicable, moat for bundle-ID + SQL specifics, sentinel test exemption documented for aggregate-only reads.

Next phase: T7 (TBD — see master spec §4 phase decomposition; likely WHERE STOPPED enrichment or AI subagent rollup).
