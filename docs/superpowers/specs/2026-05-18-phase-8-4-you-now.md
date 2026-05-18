# Phase 8.4 — YOU·NOW block wire-up

**Track:** 8 (Home as Operational Console) · P4
**Branch:** `feature/phase-8-4-you-now` (off `feature/phase-8-1-substrate` HEAD `e93b97fd`)
**Predecessors:** Phase 8.1 (substrate landed), Phase 8.2 (HomeView shell + placeholder), Phase 8.3 (TODAY block wired)
**Master contract:** [`2026-05-18-track-8-home-ux-design.md`](./2026-05-18-track-8-home-ux-design.md) §4.2, §8.3, §9 P4
**Author/agent:** Dmitrii / claude-opus-4-7

---

## 1. Scope

Replace the Phase 8.2 `YouNowBlock` placeholder with a real 4-state, color-themed dashboard cell wired through `InsightsSnapshot.youNowState` → `DerivedInsights.youNowState(now:)`. Phase 8.1 already shipped:

- `YouNowState` enum + 4 payload structs (`YouNowActive`, `YouNowMeeting`, `YouNowFocus`, `YouNowAway`)
- `DerivedInsights.youNowState(now:)` protocol method
- `ProdInsights+YouNowState.swift` impl in `LeafCorePrivate/Prod/Insights/` (moat)
- `YouNowStateDeriver` pure-function with priority resolution (`inMeeting > deepWorkFocus > away(screenLocked) > away(idle) > active > away(degenerate)`)
- `ProdInsightsYouNowStateTests` + `YouNowStateDeriverTests`

P4 takes that substrate and surfaces it on Home. One substrate touch-up is in-scope (carry `frontmostBundleID` through deriver to enable Resume CTA gate against `LocalAppsStore`).

### 1.1 Hard exclusions

- **WITH YOU ON THIS** wire-up (P5).
- **INBOX** wire-up (P6).
- **WHERE YOU STOPPED** wire-up (P7).
- **Activity → Analytics rename** (P8).
- **Polish / accessibility audit / performance / narrow-window `ViewThatFits`** (P9).
- **Real meeting title fetch** (substrate `meetingTitle: nil` hard-coded — separate substrate track). View must render generic "In a meeting" when title nil.
- **Real meeting `endsAtMs` fetch** (substrate `meetingEndsAtMs: nil` hard-coded). View hides "ends in X" when nil.
- **Zoom meeting source** (substrate only sets `.eventKit` for `meeting_state_entered` events; Zoom path inactive). View shows meeting generically.
- **Live `INFocusStatusCenter` observer in view** — Focus state is sourced from event transitions (`focus_mode_enabled`/`_disabled`) in substrate; view refreshes on `InsightsReader.refresh()` cadence.
- **Bundle-id app icon resolution** (use generic SF Symbol per state; per-app icon polish in P9 if cross-cuts).
- **"Connect this app to enable Resume" prompts** for non-`LocalAppsStore.enabled` apps — silent fallback to base away render.
- **AI narrative** (v1.1 + post-Track-8).

### 1.2 Carry-forward (from §9.1 master spec backlog)

P3 wrap-up left **C-1..C-4** in master spec §9.1. None of them are P4 scope. If P4 implementation surfaces a polish item that touches YOU·NOW but doesn't fit (e.g., narrow-window layout), **append to §9.1**, raise in conversation — do **not** silently rope into P4.

---

## 2. State → visual mapping (resolved tokens)

Master spec §4.2 uses shorthand `LeafColor.accent` / `.info` / `.warn` / `.muted`. Resolved to actual Theme tokens:

| State | Hero tint (LeafIconChip + label color) | Leading SF Symbol (LeafIcons) | Surface |
|---|---|---|---|
| `active` | `LeafColor.accent.primary` (green) | `play.circle.fill` (or `bolt.fill`) | `LeafCard(padding: .regular)` — neutral |
| `inMeeting` | `LeafColor.status.info` (blue) | `video.fill` | `LeafCard(padding: .regular)` |
| `deepWorkFocus` | `LeafColor.status.warning` (amber) | `moon.fill` (Focus mode glyph) | `LeafCard(padding: .regular)` |
| `away(.screenLocked)` | `LeafColor.text.tertiary` (grey) | `lock.fill` | `LeafCard(padding: .regular)` |
| `away(.idle)` | `LeafColor.text.tertiary` (grey) | `moon.zzz.fill` | `LeafCard(padding: .regular)` |
| `away(.sleep)` | `LeafColor.text.tertiary` (grey) | `powersleep` | `LeafCard(padding: .regular)` |

**Design rationale:** mirrors `LeafBanner` precedent — tone-tinted leading `LeafIconChip` + neutral card surface, no fully colored card backgrounds (HIG-loud, Liquid-Glass-incompatible). Title text in tone color, supporting text in `LeafColor.text.secondary`.

**Specific icon assets** look up via existing `LeafIcons` namespace (resolved during implementation; fall back to literal `Image(systemName:)` when no LeafIcons alias exists — note any additions in plan).

---

## 3. Card body composition

### 3.1 Common header (always rendered)

```
[YOU · NOW]                                    <- leafSectionLabel, text.tertiary
LeafCard {
    HStack(spacing: LeafSpace.md) {
        LeafIconChip(asset: stateIcon, size: ?, tint: stateTone)
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            // state-specific lines below
        }
        Spacer(minLength: 0)
    }
}
```

### 3.2 Per-state content rows

| State | Line 1 (title — `LeafType.title.small`, tone color) | Line 2 (`LeafType.body.small`, `text.secondary`) | Line 3 (footer — `LeafType.body.small`, `text.tertiary`) |
|---|---|---|---|
| `active` | `{app}` (e.g., "Xcode") | `{contextLabel ?? "—"}` · `{branch}` · `{linearID}` (drop empties, separator `·`) | `{durationSec→"42m"}` · `{intensityBars}` (▮▮▮▯, 4 rectangles, opacity 1.0 / 0.25) |
| `inMeeting` | `{titleIfAvailable ?? "In a meeting"}` | `Started {relativeTime(startedAtMs)}` | `{endsAtMsIfAvailable.map { "Ends \(relativeTime($0))" } ?? ""}` (row omitted if nil) |
| `deepWorkFocus` | `Deep work: {modeName ?? "Focus"}` | `{app ?? "—"}` · `{contextLabel ?? ""}` | `{durationSec→"42m"}` |
| `away(.screenLocked)` | `Screen locked` | `{lastApp.map { "Last in \($0)" } ?? "No recent activity"}` · `{lastContextLabel ?? ""}` | `{idleSec→"locked 12m ago"}` |
| `away(.idle)` | `Idle` | `{lastApp.map { "Last in \($0)" } ?? "No recent activity"}` · `{lastContextLabel ?? ""}` | `{idleSec→"idle 18m"}` |
| `away(.sleep)` | `Asleep` | `{lastApp.map { "Last in \($0)" } ?? ""}` | `{idleSec→"slept 1h 20m ago"}` (relative) |

**Duration / idle formatter:** existing `LeafTimeFormatter` (or equivalent in Track-7 surface details) — verify during implementation; if no shared formatter exists, build a local 4-line helper:
- `< 60s` → `"\(s)s"`
- `< 60m` → `"\(s/60)m"`
- `< 24h` → `"\(h)h \(m)m"` (omit `0m`)
- `≥ 24h` → `"\(days)d"`

### 3.3 Resume CTA (only on `away` + all conditions met)

Per master spec §4.2:

```
if state == .away(let a)
   && a.lastAppBundleID != nil
   && localAppsStore.isEnabled(a.lastAppBundleID!)
   && a.lastLinearID != nil
   && a.idleSec <= 86_400      // ≤24h cap
{
    // render as additional row inside the card, separated by LeafSpace.sm:
    Button {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.lastAppBundleID!) {
            NSWorkspace.shared.open(url)
        }
    } label: {
        Text("→ Resume on \(a.lastLinearID!) in \(a.lastApp ?? "app")")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.accent.primary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Resume work on \(a.lastLinearID!) in \(a.lastApp ?? "app")")
    .accessibilityAddTraits(.isButton)
}
```

**No background coloring**, no LeafButton chrome — text-link affordance keeps the card calm and consistent with INBOX item-row style. Underline / hover state is future polish (P9).

When any of the 4 conditions fails: card collapses to base `away` render (3 rows above, no CTA). No "connect this app to enable resume" disclosure on Home — that nudge lives in Settings → Connections.

### 3.4 Card tap behaviour

Per spec §4.2 click matrix:

| State | Tap outcome |
|---|---|
| `active` | No-op (it's your own state — no drill-down) |
| `deepWorkFocus` | No-op |
| `inMeeting` | If `source == .eventKit` → no-op for P4 (Calendar deep-link is post-Track-8 polish; spec says "opens Calendar app" but Calendar URL scheme `ical://` needs research — out of P4 scope). Document as P9 polish item. |
| `away` | Equivalent to Resume CTA tap (same NSWorkspace.open code path). When CTA conditions not met → no-op. |

**P4 ship:** `inMeeting` tap = no-op; document `ical://` exploration in §9.1 carry-over. `away` tap → triggers the same Resume action when CTA visible; no-op otherwise. Implementation uses a single `.onTapGesture { handleTap() }` on the card with switch.

---

## 4. Substrate touch-up (in-scope)

### 4.1 `YouNowAway.lastAppBundleID: String?`

`ProdInsights+YouNowState.swift:34` resolves the bundleID into a displayName via `AppNameResolver.shared.displayName(for:)` before handing to `YouNowInputs.frontmostAppName`. `YouNowAway.lastApp` carries only the displayName. The view needs the bundleID to gate Resume CTA against `LocalAppsStore.isEnabled(_:)`.

**Change:** add `public let lastAppBundleID: String?` to `YouNowAway` (between `lastApp` and `lastContextLabel`).

**Init:** new ordered param `lastAppBundleID: String?` after `lastApp:`.

**Deriver wiring:** `YouNowStateDeriver.swift` constructs `YouNowAway` in 3 sites (screenLocked / idle / degenerate). All three branches pass `lastAppBundleID: inputs.frontmostBundleID` (already present in `YouNowInputs`). Degenerate fallback (line 110) passes `nil` since no frontmost.

### 4.2 `YouNowState.empty` static

Mirror `TodayMetrics.empty` pattern. Single source of truth for "no signal" default — used by `InsightsSnapshot.youNowState` default param and by `StubInsights.youNowState`.

```swift
extension YouNowState {
    /// Empty / cold default: idle away with no signal context.
    public static let empty: YouNowState = .away(
        YouNowAway(
            reason: .idle,
            lastApp: nil,
            lastAppBundleID: nil,
            lastContextLabel: nil,
            lastLinearID: nil,
            idleSec: 0
        )
    )
}
```

### 4.3 `InsightsSnapshot.youNowState` field

Mirror `todayMetrics`:

- Field after `todayMetrics`: `public let youNowState: YouNowState`
- Two init signatures (line 174 main, line 266 convenience) get `youNowState: YouNowState = .empty` default param
- Two assignments at line 216 and line 309 mirror existing `self.todayMetrics = todayMetrics`

No fixture sweep needed — defaulted-init pattern preserves all existing `InsightsSnapshot` constructions across tests.

### 4.4 `StubInsights.youNowState` (DerivedInsights.swift)

Already exists (line 247–256). Update to use `lastAppBundleID: nil` in the YouNowAway constructor (or replace whole body with `YouNowState.empty`).

### 4.5 `InsightsReader.refresh()` wiring

`Leaf/Models/InsightsReader.swift:156` adds:
```swift
let youNowState = try insights.youNowState(now: Date())
```
immediately after the existing `todayMetrics` call. Line 195 adds `youNowState: youNowState` parameter to the snapshot init. No new try/catch — `DerivedInsights.youNowState(now:)` throws follow existing pattern (caught at the outer `do` block already handling `todayMetrics` failures).

### 4.6 `HomeView.swift:208` block call-site

```swift
// before
YouNowBlock()
    .frame(maxWidth: .infinity)

// after
YouNowBlock(state: snapshot.youNowState)
    .frame(maxWidth: .infinity)
```

Single-character delta on the parent file. LOC budget: 259 → 259 (no net new lines).

---

## 5. View architecture

```
struct YouNowBlock: View {
    let state: YouNowState
    @Environment(LocalAppsStore.self) private var localAppsStore   // for Resume CTA gate

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("YOU · NOW")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                cardContent
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: state)
            }
            .contentShape(Rectangle())                              // make whole card tappable
            .onTapGesture { handleTap() }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        switch state {
        case .active(let s):        activeContent(s)
        case .inMeeting(let m):     meetingContent(m)
        case .deepWorkFocus(let f): focusContent(f)
        case .away(let a):          awayContent(a)
        }
    }

    // 4 @ViewBuilder render methods, ~15–20 LOC each, plus tap + resume helpers.
}
```

### 5.1 Environment-injection of `LocalAppsStore`

`LocalAppsStore` is `@Observable` (verified Stage 1). View consumes via `@Environment(LocalAppsStore.self)`. If the store is not yet injected at the HomeView level, the implementation step adds the injection at the app-root level (single `.environment(localAppsStore)` modifier in `LeafApp.swift` or equivalent). Verify-first; if already injected, skip.

**Test concern:** since the view reads from `LocalAppsStore`, render tests would need to inject a stub. Since we're not adding view-level unit tests in P4 (presentation-only, no business logic — same call made in P3 for TodayBlock), this is not a test friction.

### 5.2 Layout — half-width preserved

`HomeView.swift:207–212` already wraps `YouNowBlock()` and `WithYouOnThisBlock()` in a `HStack(alignment: .top, spacing: LeafSpace.xl) { ... .frame(maxWidth: .infinity) }`. P4 preserves this — no HomeView layout changes beyond the call-site param.

---

## 6. Tests (Phase 8.4 net new)

### 6.1 `YouNowStateDeriverTests.swift` — substrate wiring

Add or extend tests to verify `lastAppBundleID` round-trip:

- `test_awayScreenLocked_carriesFrontmostBundleID` — input `frontmostBundleID = "com.apple.dt.Xcode"`, expect `YouNowAway.lastAppBundleID == "com.apple.dt.Xcode"`.
- `test_awayIdle_carriesFrontmostBundleID` — same shape, idle branch.
- `test_awayDegenerate_lastAppBundleIDIsNil` — `frontmostBundleID == nil` → fallback branch (line 110), expect `lastAppBundleID == nil`.

### 6.2 `InsightsSnapshotTests.swift` — defaulted init

Add 1 test:
- `test_init_defaultsYouNowStateToEmpty` — call existing convenience init without passing `youNowState`, assert `snapshot.youNowState == .empty`.

### 6.3 `YouNowStateTests.swift` (new file) — empty static

Add 1 test:
- `test_empty_isAwayIdleWithZeroState` — assert `YouNowState.empty == .away(YouNowAway(reason: .idle, lastApp: nil, lastAppBundleID: nil, lastContextLabel: nil, lastLinearID: nil, idleSec: 0))`.

### 6.4 `ProdInsightsYouNowStateTests.swift` — already exists

Verify integration tests still pass after `YouNowAway.lastAppBundleID` field addition. If any direct construction of `YouNowAway` in those tests breaks compilation, fix call-sites (likely 1–3 sites; ordered-arg init forces compiler to flag).

### 6.5 View tests

**None.** Presentation-only, 4-case switch covered structurally. Matches P3 TodayBlock testing depth.

### 6.6 Privacy walkback (Stage 7 acceptance gate)

```
grep -nE "absolute_path|full_comment_body|raw_email|notes_body|prompt|tool_input|response_body|email_subject|note_body" \
    Leaf/Views/Window/Home/Blocks/YouNowBlock.swift \
    Packages/LeafCore/Sources/LeafCore/Insights/YouNowState.swift \
    Packages/LeafCore/Sources/LeafCore/Insights/YouNowStateDeriver.swift \
    Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift
```

Expected: **0 hits**. Substrate already enforces ADR-010 walkback at parser boundaries; view consumes typed fields only.

---

## 7. ShareEventTypeKey delta

**Zero.** Phase 8.4 emits no new events. Registry remains at **post-Track-6 baseline = 195** (152 baseline + 16 P1 + 8 P3 + 6 P4 + 6 P2 + 3 P5 + 4 P6 + 0 P7). No new SQLCipher migrations, no new MCP tools, no new event_kinds. **Pure UI surface phase** like P3.

AC verify (Stage 7): `git diff $(git merge-base HEAD origin/main)..HEAD -- Packages/LeafCore/Sources/LeafCore/DB/` returns empty.

---

## 8. Acceptance criteria

| AC | Check | Evidence |
|---|---|---|
| AC-1 | `YouNowAway.lastAppBundleID` field exists, ordered between `lastApp` and `lastContextLabel`. | Read of `YouNowState.swift` |
| AC-2 | `YouNowStateDeriver` passes `frontmostBundleID` into all 3 away constructions. | Inspection of `YouNowStateDeriver.swift` after edit |
| AC-3 | `InsightsSnapshot` has `youNowState: YouNowState` field + defaulted init params for both signatures. | Read of `InsightsSnapshot.swift` |
| AC-4 | `InsightsReader.refresh()` calls `youNowState(now:)` and passes through to snapshot init. | Read of `InsightsReader.swift` |
| AC-5 | `HomeView.swift:208` calls `YouNowBlock(state: snapshot.youNowState)`. | Read of `HomeView.swift` |
| AC-6 | `YouNowBlock` renders without crash on cold-empty (`.empty` default = `.away(.idle, idleSec: 0)`). Full per-state visual verification happens via AC-7..AC-10 live transitions. | Manual smoke (Stage 7) |
| AC-7 | Live state transition: lock screen for >5 min → card transitions to `away(.screenLocked)` within ≤30s (next `InsightsReader.refresh()` tick). | Manual smoke |
| AC-8 | Live: start Zoom meeting (Cal-linked) → card transitions to `.inMeeting` within ≤30s. | Manual smoke |
| AC-9 | Live: enable Focus mode "Deep work" → card transitions to `.deepWorkFocus`. | Manual smoke |
| AC-10 | Resume CTA renders when in `.away`, `lastAppBundleID` in `LocalAppsStore.enabled`, `lastLinearID != nil`, `idleSec ≤ 86_400`. Click → opens app via `NSWorkspace.shared.open`. | Manual smoke (requires LEAF-NN branch + Xcode in enabled apps + lock screen + return ≤24h) |
| AC-11 | Resume CTA hidden when any of 4 conditions fails (each individually verified or implicitly via the "if all true" path being narrow). | Manual smoke + code review |
| AC-12 | Cross-fade transition between states (≤500ms perceived, no jank). | Manual smoke |
| AC-13 | Privacy walkback grep (§6.6) → 0 hits. | `grep` command |
| AC-14 | `just check-tokens` 3-tier clean. | CI command |
| AC-15 | `just check-style` clean (swift-format + SwiftLint warnings within baseline). | CI command |
| AC-16 | All 5 xcodebuild Debug schemes (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP) succeed. | `xcodebuild build` |
| AC-17 | SPM `swift test` 0 failures (LeafCore + LeafCorePrivate). New tests from §6 added; existing 2766 XCTest + 45 Swift-Testing baseline preserved or net-positive. | `swift test` |
| AC-18 | `HomeView.swift` LOC remains ≤ 280 (P3 budget). | `wc -l` |
| AC-19 | Zero new SQLCipher migrations / event_kinds / MCP tools / ShareEventTypeKey delta. | Spec §7 |
| AC-20 | TCC Focus-mode denied graceful degrade — view never crashes when Focus permission absent (per master §11 R-6); state stays `.active` or transitions normally without ever entering `.deepWorkFocus`. | Manual smoke (test on machine without Focus permission) |

---

## 9. Risks & mitigations

| ID | Risk | Mitigation |
|---|---|---|
| R-1 | `YouNowAway.lastAppBundleID` ordered-init param addition breaks every fixture construction in tests. | Sequential TDD: add field, then chase compile errors. Likely 3–5 call-sites max (deriver + 2 deriver tests + maybe ProdInsights+YouNowState tests). Atomic commit per failure cluster. |
| R-2 | `LocalAppsStore` not injected at HomeView level → view crashes on `@Environment(LocalAppsStore.self)`. | Verify-first at Stage 1.5 / Stage 5 — read app root file (LeafApp.swift). If not injected, add the modifier as a tiny part of view-side commit. |
| R-3 | `LeafIconChip` doesn't accept arbitrary SF Symbol — only `LeafIcons.*` aliases. | Stage 5 — read `LeafIconChip.swift`. If aliases needed (e.g., `LeafIcons.state.lock`), add to `LeafIcons.swift` as part of view commit. Trivial. |
| R-4 | Cross-fade on `LeafCard` content triggers layout jump because per-state row counts differ (active has 3 rows, away potentially 4 with CTA, deepWorkFocus 3). | Use `.animation` only on opacity, not on layout. Card itself has fixed min-height via `LeafCard` token; growing/shrinking content alters intrinsic size — acceptable for half-width row (no overflow because `WithYouOnThisBlock` is still placeholder in P4 and naturally tall). Revisit if jank observed (carry-forward to §9.1). |
| R-5 | Resume CTA `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` returns nil for valid bundleID after app uninstalled. | Wrap in `if let url`; on nil, no-op silently. Carry "show error toast" as P9 polish if observed. |
| R-6 | Focus-mode TCC denied → `INFocusStatusCenter.focusStatus.isFocused` returns nil → substrate emits no `focus_mode_enabled` events → deriver never enters `.deepWorkFocus`. **This is desired graceful degrade** per master §11 R-6. View is agnostic — no special handling needed. | Document in AC-20. |
| R-7 | `meetingTitle` and `meetingEndsAtMs` are always nil in substrate (P4 doesn't change this). View renders "In a meeting" generic with no end-time. Author may find this empty/wrong. | Documented as carry-forward (§1.1 hard exclusion). Substrate enrichment is a separate future track; not P4. |
| R-8 | Tap behaviour on `.inMeeting` is no-op (Calendar deep-link not implemented in P4). User may expect tap to do something. | Documented in §3.4; carry to §9.1 backlog ("YOU·NOW inMeeting tap → Calendar app via `ical://` URL scheme"). |

---

## 10. File inventory

**Modified (LeafCore):**
- `Packages/LeafCore/Sources/LeafCore/Insights/YouNowState.swift` — add `lastAppBundleID` field to `YouNowAway` + add `YouNowState.empty` static.
- `Packages/LeafCore/Sources/LeafCore/Insights/YouNowStateDeriver.swift` — 3 sites pass `frontmostBundleID` through.
- `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift` — update `StubInsights.youNowState` (line 247).
- `Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift` — add `youNowState` field + defaulted inits.

**Modified (LeafCore tests):**
- `Packages/LeafCore/Tests/LeafCoreTests/Insights/YouNowStateDeriverTests.swift` — bundleID round-trip tests (extend or +3 new cases).
- `Packages/LeafCore/Tests/LeafCoreTests/InsightsSnapshotTests.swift` — +1 defaulted init test.

**New (LeafCore tests):**
- `Packages/LeafCore/Tests/LeafCoreTests/Insights/YouNowStateTests.swift` — +1 test for `.empty` static.

**Modified (LeafCorePrivate tests):** possibly
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Insights/ProdInsightsYouNowStateTests.swift` — chase any compile errors from `YouNowAway` ordered-init change.

**Modified (Leaf app):**
- `Leaf/Models/InsightsReader.swift` — 2 lines (call + init param).
- `Leaf/Views/Window/Home/HomeView.swift` — line 208 call-site param.
- `Leaf/Views/Window/Home/Blocks/YouNowBlock.swift` — full rewrite, 28 → ~140–160 LOC.
- `Leaf/LeafApp.swift` (or app root) — possibly add `.environment(localAppsStore)` modifier if not present. **Verify-first.**

**No change:**
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+YouNowState.swift` — already passes `frontmostBundleID` via `YouNowInputs`.
- `Packages/LeafCore/Sources/LeafCore/DB/*` — no migrations.
- Any registry / ShareEventTypeKey files.

---

## 11. Out-of-spec (open questions explicitly deferred)

| OQ | Question | Resolution |
|---|---|---|
| OQ-P4-1 | Should the meeting-state row tap also try `ical://` Calendar deep-link in P4? | **No.** Out of P4 scope per §3.4. Carry to master §9.1 as "YOU·NOW inMeeting tap → Calendar deep-link". |
| OQ-P4-2 | Should the view animate per-state hero color (color slide) vs single cross-fade? | **No** — cross-fade only. Color slide is imperceptible at 250ms and adds complexity. |
| OQ-P4-3 | Should `intensityBars` use a custom shape (rounded rect, varying widths) or just opacity 0.25/1.0? | **Opacity-only.** 4 fixed 3pt × 8pt rectangles, opacity per bar. Polish to custom shape — P9. |
| OQ-P4-4 | Should the away "Last in {app}" line render an app icon? | **No** — text only. Per-app icon resolution — P9. |
| OQ-P4-5 | When `LocalAppsStore` not injected → fail-loud or fail-quiet? | **Verify-first injection at app root.** Don't ship a quiet fallback that swallows config error — better to crash early if injection missing during dev. |

---

## 12. Done definition

- All AC §8 pass.
- Spec self-review (placeholders / consistency / scope / ambiguity) clean.
- Independent code review (Stage 6) approve or approve-with-nits all-applied.
- Manual smoke (Stage 7) confirms 4 live state transitions.
- Final commit `docs(shared): Phase 8.4 landed — current-state update` on `feature/phase-8-4-you-now`.
- FF merge into `feature/phase-8-1-substrate` (continuing the Track-8 stack).
- `.claude/plans/phase-8-5-prompt.md` drafted for next session (WITH YOU ON THIS).

---

*End of spec.*
