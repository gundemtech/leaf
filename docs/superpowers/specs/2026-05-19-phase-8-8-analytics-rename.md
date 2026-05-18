# Phase 8.8 — Activity → Analytics rename (P8)

**Status:** Draft → User review gate → implementation.
**Branch:** `feature/phase-8-8-analytics-rename` (off `feature/phase-8-1-substrate` `866dd04f`).
**Track:** Track-8 Home UX redesign.
**Substrate base:** None (no Phase 8.1 substrate consumed — pure rename + minimal placeholder view).
**Target destination:** `WindowSection.analytics` renders `AnalyticsView()` placeholder; old `ActivityView` + supporting rows deleted.
**Master spec:** `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` §5.

---

## 1. Scope

P8 swaps the misleading "Activity" tab for an honest "Analytics" placeholder. Three mechanical operations:

1. **Rename** the navigation enum case (`WindowSection.activity` → `.analytics`) + tab title ("Activity" → "Analytics") + icon enum case (`LeafIcon_Nav.activity` → `.analytics`) + Asset.xcassets imageset folder + inner SVG file.
2. **Replace** the view body — delete `ActivityView.swift` + `SessionRow.swift` + `ActivityRow.swift`; add minimal `AnalyticsView.swift` (header + `LeafEmptyState` "coming soon" inside a `LeafCard`).
3. **Preserve** all substrate types consumed by MCP (`ActivityFeedMapper`, `ActivityFeedEntry`, `ActivitySession`, `EventKindIcon`).

Zero new SQLCipher migrations, zero new event_kinds, zero new MCP tools, zero `ShareEventTypeKey` delta (registry frozen at 195 baseline post-Track-6), zero new substrate API additions.

### 1.1 Out of scope (hard exclusion)

- **Week-scoped surface chip strip** (master spec §5 line 273). Mirroring TODAY pills scaled to a week requires either a new `DerivedInsights.weeklyMetrics(now:)` method (substrate expansion violating "substrate-only swap" P8 framing) or reuse of `todayMetrics().surfacePills` mislabeled as "this week" (wrong data). Honest empty shell ("Analytics view coming soon") beats half-shipped strip. → Carry **C-23** to master spec §9.1 (lands with real Analytics content design in Track-9).
- **Real Analytics surface** (week breakdown chart, deep-work streaks, peak-hour, top tools, WoW deltas, AI ratio over time, etc.) per master spec §5 line 275 — explicit deferral to separate brainstorm + spec ("Track-9", post Track-8 wrap).
- **HIG / a11y / perf sweep** (P9). **Manual smoke** (Track-8 wrap). **AI narrative** (v1.1).
- **`AppRoute` deep-link case rename** — no `.activity` case exists on `AppRoute` enum; navigation is sidebar-only via `WindowState.section` binding. No backwards compat needed.

---

## 2. Architecture

Three substrate layers, each preserved or renamed atomically:

| Layer | What changes | What survives |
|---|---|---|
| **Asset Catalog** | `leaf-nav-activity.imageset/` → `leaf-nav-analytics.imageset/` (folder + inner SVG file + `Contents.json` filename ref) | All other 27 Asset.xcassets entries untouched |
| **Design tokens** | `LeafIcon_Nav.activity: String = "leaf-nav-activity"` → `LeafIcon_Nav.analytics: String = "leaf-nav-analytics"` | Rest of `LeafIcons` namespace untouched |
| **Navigation enum** | `WindowSection.activity` → `.analytics`, title `"Activity"` → `"Analytics"`, icon ref updated | All other 6 cases (`home`, `team`, `connections`, `organization`, `settings`, `profile`) untouched |
| **View tier** | `ActivityView.swift` (275 LOC) + `SessionRow.swift` (68) + `ActivityRow.swift` (155) deleted. `Leaf/Views/Window/Activity/` folder removed. `AnalyticsView.swift` (~40 LOC placeholder) added at `Leaf/Views/Window/Analytics/AnalyticsView.swift` | `ActivityFeedMapper.swift` (LeafCore, 994 LOC, MCP consumer), `EventKindIcon.swift` (LeafCore, used by MCP), `ActivityFeedEntry` / `ActivitySession` (substrate types) |
| **Call-sites** | `RootView.swift:65` switch case `.activity: ActivityView()` → `.analytics: AnalyticsView()`. `Sidebar.swift:34` group items `[.home, .activity]` → `[.home, .analytics]`. `TokensIconsSection.swift:60` `nav.activity` → `nav.analytics` | All other navigation/sidebar code paths untouched |

No new types introduced apart from `AnalyticsView`. No protocol changes. No type-erasure refactor. No view-model layer. The placeholder view is intentionally trivial — the real Analytics surface lives in Track-9.

---

## 3. UI specification

### 3.1 AnalyticsView shape

Full-screen content view. Matches `HomeView` outer shape (ScrollView vertical + header) but trivialized — no `InsightsReader` dependency, no `RouteCoordinator` dependency, no `@Observable` reads. Static placeholder.

```swift
struct AnalyticsView: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                header
                placeholderCard
            }
            .padding(LeafSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        Text("Analytics")
            .leafTitle()
            .foregroundStyle(LeafColor.text.primary)
    }

    private var placeholderCard: some View {
        LeafCard(padding: .regular) {
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Analytics view coming soon",
                description: "Patterns, trends, and weekly summaries will land here."
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

Empty state icon parity with P6 INBOX / P7 WHERE STOPPED (`LeafIcons.brand.leaf`). Copy lifted verbatim from master spec §5 line 272 ("Patterns, trends, and weekly summaries will land here.") with the title hoisted into the empty-state component instead of inlined.

Header font — `.leafTitle()` (matches Connections / Organization view headers — no `LeafHeader` organism in repo, plain `Text` styled with token modifier per existing convention; verify token name during T4 implementation — if `.leafTitle()` not present, fall back to `.leafSectionLabel()` scaled up via `LeafFont.heading.size(.lg)` per `LeafText` precedent).

### 3.2 No tap targets

Placeholder view has no interactive elements — no buttons, no navigation links, no chip strip. User cannot "drill into" Analytics surface during P8. Navigation back to other tabs remains via Sidebar.

### 3.3 No animation

Static view, no state transitions. No `@State`, no `@Observable` reads. SwiftUI re-evaluation per appearance is sufficient.

### 3.4 LOC budget

AnalyticsView.swift target: **~40 LOC** (file header comment + import + struct body). Hard cap 60 LOC — if implementation creeps past, that signals scope drift toward real Analytics content (which belongs in Track-9, not P8).

---

## 4. Data flow

```
(none)

No InsightsReader read.
No RouteCoordinator dispatch.
No DerivedInsights call.
No SQL query.

AnalyticsView is a pure placeholder — header + LeafCard + LeafEmptyState.
```

When Track-9 lands the real Analytics surface, it will add reads against
`DerivedInsights.timeInApp(period:)`, `focusSessions(period:)`,
`peakProductivityHour()`, `weekOverWeekDelta()`, `aiRatio(period:)`, and
the future `weeklyMetrics(now:)` substrate addition. None of those reads
exist in P8.

---

## 5. Types & call-sites

### 5.1 Asset Catalog — `Leaf/Assets.xcassets/Icons/`

**Before:**
```
Icons/leaf-nav-activity.imageset/
    Contents.json   (filename: "leaf-nav-activity.svg")
    leaf-nav-activity.svg
```

**After:**
```
Icons/leaf-nav-analytics.imageset/
    Contents.json   (filename: "leaf-nav-analytics.svg")
    leaf-nav-analytics.svg
```

Same SVG content (the glyph art doesn't change). Only the filename + folder name. `Contents.json` `"preserves-vector-representation": true` and `"template-rendering-intent": "template"` flags preserved.

### 5.2 `LeafIcons.swift` — `Leaf/Theme/Primitives/LeafIcons.swift:33`

**Before:**
```swift
static let activity: String = "leaf-nav-activity"
```

**After:**
```swift
static let analytics: String = "leaf-nav-analytics"
```

Position in enum preserved (between `settings` and `connections` for source-control diff cleanliness).

### 5.3 `WindowState.swift` — `Leaf/Models/WindowState.swift`

**Enum case** (line 6):
```swift
case home, analytics, team, connections, organization, settings, profile
```

**Title mapping** (line 13):
```swift
case .analytics: "Analytics"
```

**Icon mapping** (line 28):
```swift
case .analytics: LeafIcons.nav.analytics
```

Position in enum preserved (between `home` and `team`).

### 5.4 `Sidebar.swift` — `Leaf/Views/Window/Sidebar.swift:34`

**Before:**
```swift
group(title: "LEAF", items: [.home, .activity])
```

**After:**
```swift
group(title: "LEAF", items: [.home, .analytics])
```

### 5.5 `RootView.swift` — `Leaf/Views/Window/RootView.swift:65`

**Before:**
```swift
case .activity: ActivityView()
```

**After:**
```swift
case .analytics: AnalyticsView()
```

### 5.6 `TokensIconsSection.swift` — `Leaf/Views/Tokens/Sections/TokensIconsSection.swift:60`

**Before:**
```swift
IconItem(id: "nav.activity", label: "activity", source: .asset(LeafIcons.nav.activity)),
```

**After:**
```swift
IconItem(id: "nav.analytics", label: "analytics", source: .asset(LeafIcons.nav.analytics)),
```

Affects `⌘⌥T` Tokens Preview only — no production user-facing impact, but kept in sync so the design-system browser stays accurate.

### 5.7 New file — `Leaf/Views/Window/Analytics/AnalyticsView.swift`

Body per §3.1. File header comment:

```swift
//
//  AnalyticsView.swift
//  Track 8 / Phase 8.8 — Analytics tab placeholder. Replaces the prior
//  ActivityView (Sessions feed + raw events list) which actively misled
//  users with noisy data and no insight. Real Analytics surface (week
//  breakdown chart, deep-work streaks, peak-hour, top tools, WoW deltas)
//  lands in Track-9 after Track-8 wraps.
//
```

### 5.8 Deleted files

- `Leaf/Views/Window/Activity/ActivityView.swift` (275 LOC)
- `Leaf/Views/Window/Activity/SessionRow.swift` (68 LOC)
- `Leaf/Views/Window/Activity/ActivityRow.swift` (155 LOC)
- `Leaf/Views/Window/Activity/` empty folder

**Total deletion:** 498 LOC of view-tier code.

### 5.9 Cosmetic doc-comment touch-ups

Two non-blocking doc-comment references become misleading after T5 deletion. Update inline as part of T5:

- `Leaf/Resources/AppIconResolver.swift:8` — comment mentions `SessionRow` consumer. Strip mention (resolver is now consumed only by `LocalAppRow` + other surfaces).
- `Packages/LeafCore/Sources/LeafCore/Insights/EventKindIcon.swift:4` — comment mentions `ActivityRow` consumer. Strip mention (icon dispatcher is now consumed by `LeafMCP/Tools/RecentActivityTool` and any future Analytics surface).

Neither change affects code behavior; both keep documentation accurate after the rename.

---

## 6. Carry-overs to master spec §9.1

Append at end of §9.1 P9 carry-over backlog (after C-22):

- **C-23 Analytics surface real content (Track-9 follow-up).** Phase 8.8 ships a static placeholder ("Analytics view coming soon") with no chip strip, no week breakdown, no streaks, no peak-hour, no top-tools, no WoW deltas. Master spec §5 line 273 calls for a week-scoped surface chip strip mirroring TODAY pills, and §5 line 275 explicitly defers full content design ("Track-9, to be decided after Track-8 lands"). Resolution = dedicated Track-9 brainstorm + spec covering substrate additions (`DerivedInsights.weeklyMetrics(now:)` or equivalent), LeafCorePrivate Prod impl, and the full Analytics surface design (charts, streaks, deltas). File: `Leaf/Views/Window/Analytics/AnalyticsView.swift` + `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift`.

---

## 7. Privacy walkback audit

### 7.1 No new payload surface

AnalyticsView reads no event data, no payload, no derived insights, no presence state. Pure static SwiftUI view. No raw event payload, no comment body, no email subject, no full file content, no prompt text reaches the view.

The deleted `ActivityView` previously consumed `InsightsReader` (sessions feed + raw events feed via `ActivityFeedMapper`). That consumption path is removed entirely; substrate-side `ActivityFeedMapper` remains because `LeafMCP/Tools/RecentActivityTool` still calls it. **Privacy posture unchanged** — the ADR-010 walked surface is now consumed only by MCP (already privacy-audited), not by the UI tab.

### 7.2 No sentinel-injection test required

Pattern parity:

- **P3 / P4 / P5 / P7** — derived metrics / state enums / opaque IDs only → no sentinel.
- **P6 INBOX** — sentinel test mandated because INBOX item titles carry untyped strings derived from Layer B / D3 contexts where comment bodies could leak.
- **P8** — AnalyticsView reads nothing. → No sentinel-injection test.

### 7.3 Grep verification (CI gate)

```bash
grep -nE "absolute_path|full_comment_body|raw_email|notes_body|prompt|tool_input|response_body|email_subject|note_body|file_contents|thinking|content" \
    Leaf/Views/Window/Analytics/AnalyticsView.swift \
    Leaf/Models/WindowState.swift \
    Leaf/Views/Window/RootView.swift \
    Leaf/Views/Window/Sidebar.swift \
    Leaf/Theme/Primitives/LeafIcons.swift \
    Leaf/Views/Tokens/Sections/TokensIconsSection.swift
```

Expected: 0 hits. AC-9 in §12 below.

---

## 8. Testing strategy

### 8.1 No new tests

P8 is pure UI rename + placeholder. No new behavior to test-drive. The deletion of `ActivityView` + `SessionRow` + `ActivityRow` removes zero tests (Discovery confirmed no dedicated view-level tests existed).

Compile-time enforcement substitutes for runtime tests:

- T1 (asset rename) — build still succeeds because `LeafIcon_Nav.activity` still references `"leaf-nav-activity"`; **but** Asset.xcassets now has only `leaf-nav-analytics` → runtime image-not-found warning. Acceptable transitional state until T2 completes within the same PR.
- T2 (icon enum rename) — build fails on every `LeafIcons.nav.activity` reference until callsites updated within the same commit.
- T3 (WindowSection rename) — build fails on every `.activity` switch case until callsites updated within the same commit.
- T4 (AnalyticsView add + RootView swap) — build succeeds with new view + switch case pointing to it.
- T5 (delete files) — build still succeeds because nothing references the deleted files after T4 (RootView already swapped).

### 8.2 Preserved tests

- `ActivityFeedMapperTests.swift` — substrate mapper, unchanged
- `ActivityFeedMapperZoomP5Tests.swift` — substrate mapper extension, unchanged
- `ActivityFeedMapperLocalOSTests.swift` — substrate mapper extension, unchanged
- `EventKindIconTests.swift` — icon dispatcher, unchanged
- All other tests (Phase 8.1-8.7 substrate + Track-1..Track-7) — unchanged

### 8.3 Test count delta

Baseline post-P7: 2778 XCTest + 45 Swift-Testing = **2823 total**.
Phase 8.8: **±0** (no new tests, no deleted tests). Target: **2778 XCTest + 45 Swift-Testing = 2823 total, 0 failures, 4 skipped**.

---

## 9. Manual smoke (AC §10 from master spec)

Not blocking ship — Phase 8.4 / 8.5 / 8.6 / 8.7 manual smoke deferred to Track-8 wrap.

Spot checks during T4 + T5:

1. **Sidebar rendering** — "LEAF" group second row reads "Analytics" with renamed icon glyph. Selecting it renders `AnalyticsView` placeholder (header + LeafEmptyState card).
2. **Tab switch** — switching between Home / Analytics / Team preserves WindowState binding; no stale render artefacts.
3. **Tokens Preview (`⌘⌥T`)** — Navigation icon group third row reads "analytics" with renamed asset.
4. **No stale "Activity" string** — global search in app binary for "Activity" via runtime app reveals zero occurrences in nav chrome.

---

## 10. Build & verification

| Gate | Command | Pass criterion |
|---|---|---|
| Token fidelity | `just check-tokens` | 3-tier clean (BASE + MIGRATION + RETIRED) |
| Build matrix | `xcodebuild -scheme Leaf -configuration Debug build` × 5 schemes (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP) | 5/5 SUCCESS |
| Test suite | `swift test` | 0 failures, **2823 total** (2778 XCTest + 45 Swift-Testing) |
| Privacy walkback | grep block per §7.3 | 0 hits |
| Stale `.activity` grep | `grep -rn "WindowSection\.activity\|LeafIcons\.nav\.activity\|leaf-nav-activity\|case \.activity" --include="*.swift" Leaf/ Packages/` | 0 hits |
| Stale `ActivityView`/`SessionRow`/`ActivityRow` grep | `grep -rn "ActivityView\|struct SessionRow\|struct ActivityRow" --include="*.swift" Leaf/ Packages/` | 0 hits (`ActivityFeedMapper` / `ActivityFeedEntry` / `ActivitySession` survive — substrate) |
| Asset.xcassets parity | `ls Leaf/Assets.xcassets/Icons/leaf-nav-analytics.imageset/` | 2 files (Contents.json + leaf-nav-analytics.svg) |
| LOC delta | `wc -l Leaf/Views/Window/Analytics/AnalyticsView.swift` | ≤ 60 (target ≤ 45) |

---

## 11. Plan structure (Stage 4 input)

Six atomic commits, mechanical-rename discipline (compile-fail before rename → compile-pass after rename → commit). No TDD red→green where there's no behavior change. See `.claude/plans/phase-8-8.md` for tactical step-by-step.

1. **T1** — `feat(phase-8-8): rename Activity icon asset to Analytics`. Asset.xcassets imageset folder + inner SVG file rename + `Contents.json` filename ref update. Build still succeeds (icon enum + callsites still point to old name; image becomes missing-warning transitional).
2. **T2** — `feat(phase-8-8): rename LeafIcon_Nav.activity → .analytics`. Enum case rename + asset string update + 2 callsites (`WindowState.swift:28`, `TokensIconsSection.swift:60`). Build green, Asset.xcassets matches.
3. **T3** — `feat(phase-8-8): rename WindowSection.activity → .analytics`. Enum case + title "Analytics" + 4 callsites (`WindowState.swift:6,13,28`, `Sidebar.swift:34`, `RootView.swift:65` still pointing to `ActivityView()` transitionally). Build green.
4. **T4** — `feat(phase-8-8): add AnalyticsView placeholder + RootView swap`. New file `Leaf/Views/Window/Analytics/AnalyticsView.swift` (header + LeafCard + LeafEmptyState) + `RootView.swift:65` swap to `AnalyticsView()`. Build green.
5. **T5** — `feat(phase-8-8): delete obsolete Activity tab view files`. `rm` `Leaf/Views/Window/Activity/ActivityView.swift` + `SessionRow.swift` + `ActivityRow.swift` + empty folder. Doc-comment touch-ups in `AppIconResolver.swift:8` + `EventKindIcon.swift:4`. Run all stale-grep gates per §10.
6. **T6** — `feat(phase-8-8): master spec §9.1 carry-over C-23 + final verification`. Append C-23 to master spec §9.1. Run all gates from §10 (build matrix × 5 + SPM tests + check-tokens + privacy walkback grep + stale-`.activity` grep + Asset.xcassets parity check). Update `.claude/shared/current-state.md` with landing summary as separate Stage 8 ship commit.

---

## 12. Acceptance summary

| AC | Check |
|---|---|
| AC-1 | `Leaf/Assets.xcassets/Icons/leaf-nav-analytics.imageset/` exists with `Contents.json` + `leaf-nav-analytics.svg`; old `leaf-nav-activity.imageset/` removed |
| AC-2 | `LeafIcon_Nav.analytics: String = "leaf-nav-analytics"` defined in `LeafIcons.swift`; no `.activity` case remains |
| AC-3 | `WindowSection.analytics` enum case exists with title "Analytics" and icon `LeafIcons.nav.analytics`; no `.activity` case remains |
| AC-4 | `Leaf/Views/Window/Analytics/AnalyticsView.swift` exists, ≤ 60 LOC, renders header "Analytics" + `LeafCard` + `LeafEmptyState` with `LeafIcons.brand.leaf` icon and copy "Analytics view coming soon" / "Patterns, trends, and weekly summaries will land here." |
| AC-5 | `RootView.swift` switch case `.analytics: AnalyticsView()` exists |
| AC-6 | `Sidebar.swift` "LEAF" group items `[.home, .analytics]` |
| AC-7 | `TokensIconsSection.swift` references `nav.analytics` / `LeafIcons.nav.analytics` |
| AC-8 | `Leaf/Views/Window/Activity/` folder removed + 3 source files deleted |
| AC-9 | Privacy walkback grep (§7.3) returns 0 hits in Phase 8.8 file scope |
| AC-10 | Stale `.activity` / `LeafIcons.nav.activity` / `leaf-nav-activity` grep returns 0 hits (§10 row 5) |
| AC-11 | `ActivityFeedMapper.swift` + `ActivityFeedEntry` + `ActivitySession` + `EventKindIcon.swift` survive (MCP consumers); `ActivityFeedMapperTests` + `EventKindIconTests` unchanged |
| AC-12 | `just check-tokens` clean across 3 tiers |
| AC-13 | All 5 xcodebuild schemes Debug build SUCCESS |
| AC-14 | `swift test` 0 failures, 2823 total (2778 XCTest + 45 Swift-Testing); ±0 vs P7 baseline |
| AC-15 | No new SQLCipher migrations (verify `git diff feature/phase-8-1-substrate -- Packages/LeafCore/Sources/LeafCore/DB/` empty) |
| AC-16 | No new event_kinds / ShareEventTypeKey delta (verify `git diff feature/phase-8-1-substrate -- Packages/LeafCore/Sources/LeafCore/Privacy/ShareEventTypeKey.swift` empty) |
| AC-17 | No new MCP tools (verify `git diff feature/phase-8-1-substrate -- Packages/LeafCore/Sources/LeafCore/MCP/ Packages/LeafCore/Sources/LeafCore/MCP*/ LeafMCP/` empty) |
| AC-18 | Master spec §9.1 appended C-23 entry |
| AC-19 | `AnalyticsView.swift` ≤ 60 LOC (target ≤ 45) |

---

## 13. Open questions

1. **`.leafTitle()` token availability.** Spec §3.1 assumes `.leafTitle()` is the canonical large-header modifier (matches Connections / Organization view headers). If the actual token name is different (e.g., `.leafHeaderLg()` / `.leafSectionTitle()`), fall back to `Text("Analytics").font(LeafFont.heading.size(.lg)).foregroundStyle(LeafColor.text.primary)` per `LeafText` precedent. Verify during T4 implementation by grepping existing view headers; pick whichever matches Connections/Organization. Decision criterion: visual parity with Connections header, not naming purity.
2. **Empty-state copy split.** Spec §3.1 lifts title into `LeafEmptyState.title` and description into `.description`. Master spec §5 line 272 inlined both into a single sentence ("Analytics view coming soon. Patterns, trends, and weekly summaries will land here."). T4 implementation picks split-into-two for visual hierarchy (title bold, description tertiary) — matches P6 INBOX + P7 WHERE STOPPED empty-state shape. If review prefers single-sentence inline, fold both into `description` and drop `title`.
3. **Doc-comment touch-up scope.** T5 §5.9 updates `AppIconResolver.swift:8` + `EventKindIcon.swift:4` comments. If reviewer flags as scope creep, defer to a separate hygiene commit post-T6 (still within phase-8-8 branch). Default = keep inline in T5 (zero behavior change, prevents stale doc rot).
