# Track-10 Phase A — Design-system polish + a11y close-out

**Linear:** GUN-A (placeholder; rename retroactive after Дима creates web UI issue)
**Status:** IN PROGRESS — Stage 3 spec landing.
**Parent:** master spec §9.2 carries C-T10-EMIT-T9-A11Y / C-T10-EMIT-T9-HIG / C-T10-EMIT-T9-A11Y-PRIMITIVES / C-T10-EMIT-T7-A11Y.
**Branch:** `feature/GUN-A-track-10-design-polish-a11y` off `feature/track-10-operational-home` tip `d22f5b61` (Track-10 T9 SHIPPED).
**Date:** 2026-05-23.

---

## 1. Scope

Closes 11 deferred NITs from Track-10 T9 sweeps + T7-A11Y forward carry + design-system primitive a11y trait drift. **Zero substrate touch** — view-layer + theme-layer only. Substrate-purity invariant held (registry frozen 198 · 30 tables · 15 MCP tools).

After Phase A SHIPPED → master spec §9.2 closes 4 carries (T9-A11Y · T9-HIG · T9-A11Y-PRIMITIVES · T7-A11Y), leaving only T7H1/H2/H3 + C-25 + standup-hours/mcp/flake/loc-info for follow-up phases B + C.

### 1.1 In-scope (11 fixes)

**A11y NITs (5):**
1. `NeedsYouFilterRow` + `SinceFilterRow` already got pluralization in T9 inline. Verify; no diff needed.
2. `TeamNBlock` section-header label "Team, \(count) active" — 0/1 pluralization edge ("0 active" / "1 member active" / "N members active").
3. `SinceLastActiveBlock` "Mark all as seen" Button — missing `.accessibilityHint` ("Advances the last-seen cursor so the SINCE block resets next refresh.").
4. `RecapBlock` + `EodBlock` outer VStack — add `.accessibilityElement(children: .combine)` so toggling the header fires a VO refresh on the empty-state content below.
5. `ResumeHeroBlock` last-commit subject + WIP line — strip literal quote-marks from `.accessibilityLabel` (`"Last commit: \"foo\""` → `"Last commit: foo"`).

**HIG NITs (5):**
6. `TeamNBlock` avatar `width: 32, height: 32` raw literal → `LeafSpace.xxl` token (32pt, semantic mapping — already-existing design token).
7. `StandupHeaderRow` chevron `frame(width: 12)` raw literal → `LeafSpace.md` token (12pt).
8. `YoureOnBlock` empty-state — current `Text("No active task identified. Leaf reads LEAF-XXX from branch names...")` splits into `LeafEmptyState(title:description:)` pattern (HIG empty-state guidance: short title + optional descriptive body).
9. `RecapBlock` + `EodBlock` empty-state — currently plain `Text`; HIG sweep noted collapsible-card footprint caveat → introduce `LeafEmptyState` **compact variant** (no 64pt chip, smaller padding) and adopt.
10. `ResumeHeroBlock` `taskLineTrimmed(...)` manual `String(prefix(60)) + "…"` → native `.lineLimit(1) + .truncationMode(.tail)` (sibling `anchorLine` already uses native pattern).

**Design-system primitive a11y trait hoist (1):**
11. `leafChipAccessibility(label:isSelected:)` view modifier in `Leaf/Theme/Composites/` — applied to Button-wrapped LeafPill chip callsites (`NeedsYouFilterRow`, `SinceFilterRow`, future block filter strips). Reduces trait drift across blocks; doesn't change runtime behavior of existing callsites (they already manually set the same traits).

**T7-A11Y forward carry close-out:**
- 4 of 5 T7 a11y NITs already closed by T9 a11y sweep (`.isHeader` on RESUME/NEEDS YOU/SINCE/TODAY). Phase A closes the 1 truly remaining (WeekChipStrip today `.isSelected`) IF Analytics surface is currently visible at all (Analytics is hidden by default per T1; the chip strip lives inside Analytics → visit is rare. Skip unless quick. Defer-to-Analytics-phase-if-required as last-resort).

### 1.2 Out of scope (hard exclusion)

- T7 post-ship moat hot-fixes (C-T10-EMIT-T7H1/H2/H3) — Phase B own scope.
- C-25 sleep/wake substrate idle gap — Phase C own scope.
- LocalAppsStore reactivity (C-5) — separate refactor.
- Resume CTA branch-deletion staleness (C-8) — v1.1.
- RECAP/EOD configurable hours (C-T10-EMIT-STANDUP-HOURS) — v1.1.
- `get_standup_summary` MCP tool (C-T10-EMIT-MCP-STANDUP) — future.
- Multi-week Analytics / TopToolsCard substrate (C-38/C-41/C-44) — separate phases.
- Pre-existing `testWarmState_HappyPath_TrackD1` flake (C-T10-EMIT-FLAKE) — separate test-infra triage.
- ResumeHeroBlock LOC informational drift (C-T10-EMIT-LOC-RESUMEHERO) — informational only; no refactor trigger unless surface bloats further.

---

## 2. Decisions (Stage 2 brainstorm self-conducted)

**D-A1.** **`LeafEmptyState.compact` variant** vs creating new `LeafCompactEmptyState`. Add `style: LeafEmptyStateTokens.Style` enum to existing struct. `.large` (default, backward-compatible) keeps current 64pt chip + verticalPadding; `.compact` swaps for inline 24pt icon chip + horizontal layout + tighter padding. Reuses LeafEmptyStateTokens cleanly.

**D-A2.** **Avatar 32 / Chevron 12 → LeafSpace.xxl / .md** semantically OK. LeafSpace is *technically* spacing-scale but uses CGFloat dimensions that map cleanly to fixed-size frames. No new LeafSize enum (avoids token proliferation). Comment at usage explains semantic.

**D-A3.** **`leafChipAccessibility(label:isSelected:)` modifier** — view modifier on the Button (not LeafPill itself, since LeafPill is a label that may or may not be wrapped in a Button). Modifier sets `.accessibilityLabel` + `.accessibilityAddTraits(.isSelected)` conditionally. The `.isButton` trait is inherited from Button automatically. Callsites change from manual `.accessibilityLabel(...) .accessibilityAddTraits(...)` chain to single `.leafChipAccessibility(...)` line.

**D-A4.** **Recap/Eod empty-state**: even with LeafEmptyState compact, the collapsible card footprint is small. Current plain `Text("Nothing captured yesterday.")` is honest and readable. Phase A choice: introduce `.compact` variant and adopt for HIG consistency; if visual review shows it's too heavy still, revert to plain Text (low-risk, easy rollback).

**D-A5.** **YoureOnBlock empty-state** — split current sentence into:
- `title = "No active task identified."`
- `description = "Leaf reads LEAF-XXX from branch names."`
Drop "Leaf reads ..." → "Leaf reads LEAF-XXX from your IDE branch names." per HIG sub-agent suggestion. Use `LeafEmptyState(style: .compact, ...)` adoption.

**D-A6.** **ResumeHeroBlock prefix(60) drop**: replace `taskLineTrimmed(_:maxLength:)` body with `.lineLimit(1)` already applied on the Text. Drop the manual function; let SwiftUI handle truncation.

**D-A7.** **T7-A11Y WeekChipStrip skip in Phase A** — Analytics is hidden by default (T1 decision); WeekChipStrip lives inside Analytics. Toggle isSelected is a trivial fix but visits are rare. Quick check: if WeekChipStrip exists + accessible from current Analytics surface, fix inline; else defer to Analytics-resurface phase (post-Track-10).

**D-A8.** **Atomic commits, ~9 total**: spec landing · a11y bundle · LeafEmptyState compact + Recap/Eod adoption · HIG NIT batch remainder · primitive a11y modifier · verification · master spec §9.2 close-out · current-state.md update · SHIPPED.

---

## 3. Per-fix implementation

### 3.1 `LeafEmptyState` compact variant

`Leaf/Theme/Layouts/LeafEmptyState.swift` — add `style` parameter:

```swift
enum Style { case large, compact }
var style: Style = .large
```

`.compact` body branch:
- Horizontal HStack instead of VStack
- Smaller icon (24pt) inline left
- Tighter spacing — no `verticalPadding`, use `LeafSpace.sm`
- Description optional, title-only OK
- No CTA support in `.compact` (out of scope; collapsibles don't need CTA)

`LeafEmptyStateTokens.swift` — add `compactChipSize` (24), `compactPadding` (LeafSpace.sm).

### 3.2 Per-block adoption

**`TeamNBlock`** — line 120 avatar Circle frame `32 × 32` → `LeafSpace.xxl × LeafSpace.xxl`. Comment `// LeafSpace.xxl = 32pt avatar (semantic mapping)`.

**`TeamNBlock`** — section header label "Team, N active" (line ~41-45):
```swift
let memberWord = teammates.count == 1 ? "member" : "members"
let labelText = teammates.isEmpty
    ? "Team, none active"
    : "Team, \(teammates.count) \(memberWord) active"
```

**`StandupHeaderRow`** — line 31 chevron `frame(width: 12)` → `frame(width: LeafSpace.md)`.

**`YoureOnBlock`** — empty-state replacement:
```swift
LeafEmptyState(
    icon: LeafIcons.brand.leaf,
    title: "No active task identified.",
    description: "Leaf reads LEAF-XXX from your IDE branch names.",
    style: .compact
)
```

**`RecapBlock` + `EodBlock`** — `Text("...")` empty-state → `LeafEmptyState(style: .compact, ...)` adoption.

**`RecapBlock` + `EodBlock`** — outer VStack: `.accessibilityElement(children: .combine)` so toggle expands → VO reads combined content.

**`SinceLastActiveBlock`** — `markAllFooter` Button: `.accessibilityHint("Advances the last-seen cursor so the SINCE block resets next refresh.")`.

**`ResumeHeroBlock`** — drop `taskLineTrimmed(_:maxLength:)`:
- Replace `Text(taskLineTrimmed(subject, maxLength: 60))` with `Text(subject).lineLimit(1).truncationMode(.tail)`.
- Strip literal quote-marks from `.accessibilityLabel` (`"Last commit: \"\(subject)\""` → `"Last commit: \(subject)"`).

**`leafChipAccessibility(label:isSelected:)` modifier** — new file `Leaf/Theme/Composites/ChipAccessibility.swift`:
```swift
extension View {
    /// Apply consistent a11y to a Button-wrapped LeafPill chip:
    /// label override + `.isSelected` trait when active.
    /// `.isButton` inherits from the Button automatically.
    func leafChipAccessibility(label: String, isSelected: Bool) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
```

Adopt in 3 chip-strip callsites: `NeedsYouFilterRow`, `SinceFilterRow`, `WeekChipStrip` (if quick).

---

## 4. Acceptance gates (Stage 7)

1. **AC-A1** — 5/5 xcodebuild schemes Debug SUCCESS.
2. **AC-A2** — SPM tests green (XCTest + Swift Testing); flake exception clause applies for `testWarmState_HappyPath_TrackD1`.
3. **AC-A3** — `just check-tokens` 3-tier clean.
4. **AC-A4** — Privacy walkback master grep across Phase A file scope: 0 hits.
5. **AC-A5** — Sentinel-injection tests preserved (no diff).
6. **AC-A6** — HomeView.swift ≤ 310 · HomeContent.swift ≤ 200 (no diff expected).
7. **AC-A7** — Substrate diff vs `dev` empty (DB/ + ShareEventTypeRegistry + LeafMCP).
8. **AC-A8** — Master spec §9.2 carries marked resolved (4 entries flipped to "RESOLVED PHASE A").
9. **AC-A9** — Visual verification: launch Debug build, screenshot of empty Recap/Eod (or expanded), verify compact LeafEmptyState reads naturally; YoureOn empty-state shows split title+description.

---

## 5. Carries after Phase A (master spec §9.2 final)

| Carry | Status post Phase A |
|---|---|
| C-T10-EMIT-T7H1 | OPEN — Phase B |
| C-T10-EMIT-T7H2 | OPEN — Phase B |
| C-T10-EMIT-T7H3 | OPEN — Phase B |
| C-T10-EMIT-T9-A11Y | RESOLVED — Phase A (5 NITs landed) |
| C-T10-EMIT-T9-HIG | RESOLVED — Phase A (5 NITs landed) |
| C-T10-EMIT-T9-A11Y-PRIMITIVES | RESOLVED — Phase A (modifier hoist + 3 adoptions) |
| C-T10-EMIT-T7-A11Y | RESOLVED — Phase A (4 inline T9 + 1 WeekChipStrip Phase A or skip) |
| C-T10-EMIT-FLAKE | OPEN — separate triage (NOT Track-10 emit) |
| C-T10-EMIT-STANDUP-HOURS | OPEN — v1.1 |
| C-T10-EMIT-MCP-STANDUP | OPEN — future |
| C-T10-EMIT-LOC-RESUMEHERO | RESOLVED — Phase A drops `taskLineTrimmed` ~5 LOC reduction |
| C-25 | OPEN — Phase C |

---

## 6. Files touched

**Created:**
- `docs/superpowers/specs/2026-05-23-track-10-phase-A-design-polish-a11y.md`
- `Leaf/Theme/Composites/ChipAccessibility.swift`

**Modified:**
- `Leaf/Theme/Layouts/LeafEmptyState.swift` (+ compact variant)
- `Leaf/Theme/Tokens/Components/LeafEmptyStateTokens.swift` (+ compact tokens)
- `Leaf/Views/Window/Home/Blocks/ResumeHeroBlock.swift` (drop `taskLineTrimmed` + strip quote-marks)
- `Leaf/Views/Window/Home/Blocks/TeamNBlock.swift` (avatar token + pluralization)
- `Leaf/Views/Window/Home/Blocks/StandupHeaderRow.swift` (chevron token)
- `Leaf/Views/Window/Home/Blocks/YoureOnBlock.swift` (empty-state → LeafEmptyState compact)
- `Leaf/Views/Window/Home/Blocks/RecapBlock.swift` (empty-state + .combine)
- `Leaf/Views/Window/Home/Blocks/EodBlock.swift` (empty-state + .combine)
- `Leaf/Views/Window/Home/Blocks/SinceLastActiveBlock.swift` (Mark-all-seen accessibilityHint)
- `Leaf/Views/Window/Home/Blocks/NeedsYouFilterRow.swift` (leafChipAccessibility adoption)
- `Leaf/Views/Window/Home/Blocks/SinceFilterRow.swift` (leafChipAccessibility adoption)
- `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` (§9.2 RESOLVED markers)
- `.claude/shared/current-state.md` (Phase A landed paragraph)

---

## 7. Workflow

Per `.claude/shared/conventions.md` 8-stage one-phase-one-session (simplified marathon-mode per user override):
1. ✅ Discovery — primitives located + tokens verified
2. ✅ Brainstorm — D-A1..D-A8 above
3. ✅ Spec write — this file
4. ✅ Plan write — atomic commits per §3
5. **NEXT**: Implementation — sequential atomic commits
6. **NEXT**: Independent review — light a11y subagent re-pass after fixes
7. **NEXT**: Verification — 9 AC gates per §4
8. **NEXT**: Ship — SHIPPED commit + FF merge to collective `feature/track-10-operational-home`
