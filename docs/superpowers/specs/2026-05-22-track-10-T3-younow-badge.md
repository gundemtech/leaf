# Track-10 T3 — YOU·NOW state badge inline phase spec

**Status**: Stage 3 (per-phase spec) closed. Authored 2026-05-22 from approved Stage 4 plan `~/.claude/plans/track-10-t3-today-zesty-steele.md` after Stages 1-2 brainstorm + Stage 4.5 CTO review (7 findings dispositioned: 3 CRITICAL inline-fixed, 2 HIGH inline-fixed, 2 MEDIUM dispositioned). Stages 5-8 (implementation / review / verification / ship) landed in the same calendar day; this spec is the post-implementation source of truth.

**Branch**: `feature/track-10-operational-home` (off Track-10 T2 SHIPPED tip `acdbf2dc`).

**Master spec contract**: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` — §4 T3 · §3.2 · §5.8 · §6 · §7.2.

**T2 precedent spec**: `docs/superpowers/specs/2026-05-22-track-10-T2-resume-hero.md`.

---

## 1. Goal

Compact the 387-LOC dedicated `YouNowBlock` (a full card in the 2-column HStack with `WithYouOnThisBlock`) into a single inline state pill at the foot of the TODAY metrics row. The Resume CTA that previously lived inside `.away` migrated to the RESUME hero in T2; the YOU·NOW surface no longer needs to be a full card — a compact tinted-capsule pill is sufficient.

T3 is a **pure UI refactor**:

- Zero new event_kinds (registry frozen at 198).
- Zero new SQLCipher migrations (30 tables preserved).
- Zero new MCP tools (15 frozen).
- Zero new `ShareEventTypeKey` entries.
- Zero new payload reads → T3 is sentinel-injection EXEMPT per master spec §6.
- `YouNowState` enum, `YouNowStateDeriver`, `DerivedInsights.youNowState(now:)`, `InsightsSnapshot.youNowState` — UNCHANGED.

Net: ~150 LOC added, 387 LOC deleted, 3 implementation commits + 1 review-fix commit + 1 spec landing commit = 5 commits. Net LOC delta across `Leaf/Views/Window/Home/` is **≈ −230 LOC**.

---

## 2. Brainstorm decisions

| Q | Decision | Reason |
|---|---|---|
| Q1 Badge shape | **Tinted capsule + icon + text** | LeafPill / LeafStatusPill family aesthetic; capsule shape carries pill semantics; icon + text scans faster than dot + label alone. |
| Q2 Duration suffix scope | **All 4 states show duration / end-time** | `.active=1h32m` / `.inMeeting=ends 11:30` (fallback `In meeting`) / `.deepWorkFocus=12m` / `.away=8m`. Single source of "how long" rather than scattered presentations. |
| Q3 Narrow-window layout | **Badge on its own trailing row in both ViewThatFits branches** | Wide: row below 5-cell HStack with right-aligned Spacer. Narrow Grid 2×3: row below the Grid mirrors wide branch (Stage 6 review I-1 fix — original "fill bottom-right cell" caused metric-cell row misalignment). |
| Q4 File location | **`Leaf/Theme/Composites/YouNowStateBadge.swift`** | Parallel to LeafBadge / LeafPill / LeafStatusPill. Composite tier, not a view-window block. |
| Q5 State icon glyphs | **Reuse `YouNowBlock` glyphs** | `active=play.fill` / `inMeeting=video.fill` / `deepWorkFocus=moon.fill` / `away(.screenLocked)=lock.fill` / `away(.idle)=moon.zzz.fill` / `away(.sleep)=powersleep`. Carry forward muscle memory. |
| Q6 Animation | **`.easeInOut(0.25)` cross-fade on state change** | Mirrors current YouNowBlock animation pattern; YouNowState is Equatable so SwiftUI cleanly interpolates discriminated-union transitions. |
| Q7 WithYouOnThisBlock interim | **Promote to full-width single block in HomeView** | The 2-col HStack collapses; T6 will replace WithYouOnThisBlock with TeamNBlock anyway. Interim full-width acceptable per master §4 T6. |
| Q8 Tap behavior on badge | **Read-only** | Resume CTA lives in RESUME hero (T2). `.inMeeting` ical-deep-link and `.deepWorkFocus` Focus-mode toggle carry to v1.1. |
| Q9 Commit decomposition | **4 atomic + 1 review fix-bundle + 1 spec** | C1 dormant primitive · C2 integration · C3 delete + cleanup · review fix-bundle · C4 spec landing. Brief visual duplication between C2 and C3 (badge in TodayBlock + full YouNowBlock card) intentional. |

---

## 3. Spec sections

### 3.1 Surface contract (`Leaf/Theme/Composites/YouNowStateBadge.swift`)

New composite. Structural reference: `LeafStatusPill.swift` (HStack + Capsule + padding + a11y combine). The pulsing-dot animation is dropped — state cycle is rare; a 0.25s cross-fade on state change is sufficient.

Per-state mapping table:

| State | Icon (SF Symbol) | Tint | Visible label |
|---|---|---|---|
| `.active(YouNowActive)` | `play.fill` | `LeafColor.accent.primary` | `Active · {formatDuration(durationSec)}` |
| `.inMeeting(YouNowMeeting)` with endsAt | `video.fill` | `LeafColor.status.info` | `In meeting · ends {HH:mm}` |
| `.inMeeting(YouNowMeeting)` no endsAt | `video.fill` | `LeafColor.status.info` | `In meeting` |
| `.deepWorkFocus(YouNowFocus)` | `moon.fill` | `LeafColor.status.warning` | `Focused · {formatDuration(durationSec)}` |
| `.away(.screenLocked)` | `lock.fill` | `LeafColor.text.tertiary` | `Locked · {formatDuration(idleSec)}` |
| `.away(.idle)` | `moon.zzz.fill` | `LeafColor.text.tertiary` | `Idle · {formatDuration(idleSec)}` |
| `.away(.sleep)` | `powersleep` | `LeafColor.text.tertiary` | `Asleep · {formatDuration(idleSec)}` |

Style:

- Capsule background: state tint @ 0.15 opacity.
- Foreground: state tint at full opacity for both icon and text.
- Padding: `LeafSpace.sm` horizontal · `LeafSpace.xs` vertical.
- Font: `LeafType.body.small` for both icon (`Image(systemName:).font(...)`) and text.
- Corner: `Capsule()` shape (no explicit `LeafRadius`).
- Animation: `.animation(.easeInOut(duration: 0.25), value: state)`. `YouNowState: Equatable` ensures cross-fade triggers cleanly on enum-with-associated-value transitions.
- Read-only — no `.onTapGesture`, no `Button` wrapper.

### 3.2 a11y contract

- `.accessibilityElement(children: .combine)` on the whole capsule.
- `.accessibilityLabel("State: <stateName>, <durationPhrase>")` with verbalised duration — e.g. `"State: Active, 1 hour 32 minutes"` · `"State: In meeting, ends 11:30"` · `"State: Idle, 8 minutes"`.
- Icon `.accessibilityHidden(true)` — label carries semantics, glyph would read literally otherwise.
- `private func accessibilityDurationPhrase(_:)` member method (CTO #4 location; Stage 6 review I-2 tightened from `fileprivate` → `private`). Handles 0/1/many for `hour` / `minute` / `second` pluralisation.

### 3.3 HH:mm formatter (locale-aware, cached)

`HH:mm` rendering for `inMeeting` end-time needs a cached, locale-respecting formatter (raw `DateFormatter()` per render fails token discipline).

```swift
private static let hourMinuteFormatter: DateFormatter = {
    let df = DateFormatter()
    df.setLocalizedDateFormatFromTemplate("Hm")  // 24h / 12h per system locale
    return df
}()
```

Static inside `YouNowStateBadge.swift`. Not added to LeafCore — formatter is UI tier (CTO #5).

### 3.4 Layout integration (`TodayBlock.swift`)

Signature gains `youNowState: YouNowState`:

```swift
struct TodayBlock: View {
    let metrics: TodayMetrics
    let youNowState: YouNowState
    ...
}
```

`metricsRow` becomes branch-aware via existing `ViewThatFits(in: .horizontal)`:

- **Wide branch** — `VStack(alignment: .leading, spacing: LeafSpace.sm)` wraps the existing 5-cell `HStack` and appends a trailing `HStack { Spacer(minLength: 0); YouNowStateBadge(...) }` (badge right-aligned).
- **Narrow branch** — `VStack(alignment: .leading, spacing: LeafSpace.sm)` wraps the existing `Grid 2×3` (whose bottom-right cell stays a `Color.clear` placeholder) and appends the same trailing badge `HStack`. This is the Stage 6 review I-1 fix; the original "fill the Grid bottom-right cell" approach broke metric-cell row alignment because the capsule's intrinsic height differs from a 2-line `metricCell`.

`HomeView.swift` post-T3:

- Callsite passes both `metrics` and `youNowState` from `snapshot`.
- The 2-column `HStack(YouNowBlock || WithYouOnThisBlock)` collapses.
- `WithYouOnThisBlock` promotes to a full-width sibling block in the main VStack.
- Block order: `ResumeHeroBlock` · `TodayBlock(metrics:youNowState:)` · `WithYouOnThisBlock` · `InboxBlock` · …
- Header doc-comment refreshed to reflect the post-T2/T3 4-block composition (Stage 6 review N-3 fix).

### 3.5 Substrate purity

```
git diff acdbf2dc..HEAD -- Packages/  →  empty
```

`YouNowState` enum at `Packages/LeafCore/Sources/LeafCore/Insights/YouNowState.swift` — untouched. `YouNowStateDeriver.derive(...)` — untouched. `DerivedInsights.youNowState(now:)` API — untouched. `InsightsSnapshot.youNowState` field — already populated (consumed today by YouNowBlock; rewired to TodayBlock via HomeView).

Reused from LeafCore: `formatDuration(_:)` at `LeafCore/Insights/DurationFormatter.swift` — single source of compact duration text across the badge and the LeafMCP tool responses.

### 3.6 Tests

The Leaf app target has no `LeafTests` test target — all 22 Theme composites (LeafBadge / LeafPill / LeafStatusPill / etc.) ship without unit tests. Tests live in SPM `Packages/LeafCore/Tests/`. Following established convention, `YouNowStateBadge` ships **without** a new view-level test file (CTO #1).

**Coverage strategy:**

- **SwiftUI `#Preview` catalog** inside `YouNowStateBadge.swift` — 7 visual variants (active / inMeeting-with-endsTime / inMeeting-without-endsTime / deepWorkFocus / away-locked / away-idle / away-sleep).
- **Manual smoke** per master spec §7.2 — cycle states by lock screen / open Zoom / enable macOS Focus / let idle and verify rendering.
- **Substrate tests UNTOUCHED** — `YouNowStateTests`, `YouNowStateDeriverTests`, `YouNowStateDeriverFocusEnrichmentTests`, `ProdInsightsYouNowStateTests` in `Packages/LeafCore/Tests/` already cover the 4-state derivation logic. T3 makes no substrate change → these stay green by definition.

### 3.7 LOC budgets

| File | Before | After | Delta |
|---|---|---|---|
| `Leaf/Theme/Composites/YouNowStateBadge.swift` (new) | — | 185 | +185 |
| `Leaf/Views/Window/Home/Blocks/TodayBlock.swift` | 123 | 137 | +14 |
| `Leaf/Views/Window/Home/Blocks/YouNowBlock.swift` | 387 | 0 | −387 |
| `Leaf/Views/Window/Home/HomeView.swift` | 276 | 271 | −5 |
| `Leaf/Views/Window/Home/Blocks/WithYouOnThisBlock.swift` | — | (−1 stale comment) | −1 |
| **Net** | | | **≈ −194** |

YouNowStateBadge overshoots the 130-180 plan target by 5 LOC, driven by the 7-variant `#Preview` catalog block. Disposition: accept the 5-LOC overshoot (no hard ceiling in plan AC).

---

## 4. Implementation commits

5 atomic commits on `feature/track-10-operational-home`:

| Commit | Hash | Subject |
|---|---|---|
| C1 | `8c6dae15` | `feat(track-10-T3): YouNowStateBadge composite + state icon/tint mapping` |
| C2 | `fb12b53c` | `feat(track-10-T3): TodayBlock embeds YouNowStateBadge in metrics row` |
| C3 | `99486842` | `feat(track-10-T3): YouNowBlock retired + HomeView 2-col cleanup` |
| Review fixes | `5f3badc7` | `fix(track-10-T3): review pass — narrow Grid alignment + access modifiers` |
| C4 | _this commit_ | `docs(track-10-T3): spec landing + current-state SHIPPED` |

---

## 5. Stage 6 — independent review findings

Independent code-reviewer subagent ran over diff `acdbf2dc..99486842` (T3 implementation commits only). 7 findings returned:

| # | Severity | Finding | Disposition |
|---|---|---|---|
| I-1 | IMPORTANT | Narrow Grid 2×3 bottom-right cell rendered a `Capsule` pill while neighbouring cells were 2-line `metricCell` (title + label) — visible row misalignment. | FIXED INLINE (commit `5f3badc7`) — badge moved out of Grid onto its own trailing row in the narrow branch, mirroring wide branch layout. Empty `Color.clear` placeholder restored in Grid bottom-right slot. |
| I-2 | IMPORTANT | `accessibilityDurationPhrase(_:)` and `hourMinuteString(_:)` were declared `fileprivate` but only called from inside the `YouNowStateBadge` struct itself. | FIXED INLINE — tightened to `private`. Aligns with LeafStatusPill discipline. |
| N-1 | NIT | `#Preview` block captures `Date()` literally inside expression closures. | DEFER — preview catalog, not live demo. Cosmetic. |
| N-2 | NIT | LOC budget overshoot 5 LOC on YouNowStateBadge (185 vs 130-180 plan target). | ACCEPT — no hard ceiling in plan AC. Documented in §3.7. |
| N-3 | NIT | HomeView opening doc comment still narrated the pre-T2/T3 "2-column grid row" composition. | FIXED INLINE — header refreshed to reflect the post-T2/T3 4-block composition (Resume hero / TODAY+badge / WithYou / Inbox). |
| N-4 | NIT | `hourMinuteFormatter` doesn't explicitly set `df.locale = .current`; sibling `TodayBlock.sectionDateFormatter` does. | DEFER — `DateFormatter` defaults to `.current`, behaviour identical. Stylistic NIT for a later UI sweep. |
| N-5 | NIT | `.animation(_:value:)` placed after `.accessibilityLabel` — reading-order NIT. | DEFER — functionally correct (animation gated on `value: state`); stylistic ordering. |

Verdict: **Ready to merge: Yes, with fix-bundle** — I-1, I-2, N-3 applied inline; N-1/N-2/N-4/N-5 carry to a future UI sweep.

---

## 6. Verification — Stage 7

Per master spec §7.2 invariants:

- ✅ 5 schemes Debug build green: `Leaf`, `LeafCore`, `LeafCorePrivate`, `LeafAgent`, `LeafMCP`.
- ✅ `just check-tokens` 3-tier clean (BASE / MIGRATION / RETIRED).
- ✅ Privacy walkback — `grep -nE "absolute_path|file_contents|payload|email_subject|note_body" Leaf/Theme/Composites/YouNowStateBadge.swift` → 0 hits. T3 is sentinel-injection EXEMPT (no new payload reads), defensive grep clean.
- ✅ Substrate purity — `git diff acdbf2dc..HEAD -- Packages/` → empty.
- ✅ `git grep YouNowBlock Leaf Packages` → 0 production hits; only narrative references in `YouNowStateBadge.swift` header / cached-formatter comment and `HomeView.swift` retirement comment.
- ✅ Token discipline — no raw `Color(...)`, no `.font(.system(`, no per-render `DateFormatter()`. `LeafColor.*`, `LeafSpace.*`, `LeafType.*` exclusively.
- ✅ a11y label readable as a single VoiceOver sentence; icon hidden so glyph names don't leak into speech.
- ✅ Track-9 invariants preserved: Analytics still hide-by-default · ResumeHeroBlock still Zone 1 · GitDeltaReader still polled · 5 TODAY metrics unchanged.

LeafCorePrivate test failure pre-existing in untracked test code (`ProdLinearGraphQLProviderTests.testWarmState_HappyPath_TrackD1` — index out of range against Linear GraphQL fixture). Unrelated to T3 (substrate diff empty). Carry — separate Linear-fixture investigation post-Track-10 merge.

Manual smoke gate (Дима driver, post-merge): launch Debug build via `open` (verify `lsof` → DerivedData, not `/Applications`); confirm TODAY 5 metrics + state badge render in wide window; resize window narrow → badge renders on its own trailing row below the Grid; cycle states (lock screen → away badge · open Zoom → inMeeting badge · enable macOS Focus → deepWorkFocus badge); VoiceOver rotor reads "State: Active, 1 hour 32 minutes" etc.

---

## 7. References

- Master spec: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md`.
- T2 precedent spec: `docs/superpowers/specs/2026-05-22-track-10-T2-resume-hero.md`.
- T1 precedent spec: `docs/superpowers/specs/2026-05-22-track-10-T1-foundation.md`.
- Structural reference for the pill: `Leaf/Theme/Composites/LeafStatusPill.swift`.
- `.claude/shared/architecture.md` — substrate baseline (untouched by T3).
- `.claude/shared/conventions.md` — 8-stage workflow.
