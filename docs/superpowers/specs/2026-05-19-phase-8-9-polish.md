# Phase 8.9 — Home UX polish + a11y + perf + Track-8 manual smoke (P9)

**Status:** Draft → User-approved → implementation.
**Branch:** `feature/phase-8-9-polish` (off `feature/phase-8-1-substrate` `c0abb7ba`).
**Track:** Track-8 Home UX redesign — final phase.
**Substrate base:** None consumed (pure view-layer polish + 2 new LeafCore helpers + Track-9 spec stub).
**Master spec:** `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` §9.1 carry-over backlog + §10 acceptance criteria (relaxed for polish phase).

---

## 1. Scope

P9 closes Track-8 with three deliverables:

1. **Resolve 6 view-only carry-overs** from §9.1 (C-3, C-4, C-7, C-17, C-18, C-22) — narrow-window fallback, DateFormatter caching, YOU·NOW Button wrap for VoiceOver, InboxBlock filteredItems unit-test coverage, empty vs no-match icon differentiation, formatRelative helper unification.
2. **Run three sweeps**: macOS HIG manual review (7 Home block files + HomeView), a11y subagent audit via `hig` skill, perf manual review (DateFormatter allocs / Equatable / ForEach IDs / animation values).
3. **Track-8 wrap manual smoke** (P3..P8 spot-checks, 6 phases) + Track-9 spec stub for the remaining 14 substrate-deferred carries.

Zero substrate touches: no new SQLCipher migrations, no new event_kinds, no new MCP tools, no `ShareEventTypeKey` delta (registry frozen at 195 baseline post-Track-6).

### 1.1 Out of scope (hard exclusion)

**Track-9 deferred (14 carries):** C-1 Hybrid surface pills (substrate emission gap) / C-2 Error-state last-known retention (`InsightsReader` state-machine refactor) / C-5 LocalAppsStore env injection (cross-cutting app-root change beyond Home) / C-6 inMeeting `ical://` deep-link (Calendar URL scheme research) / C-8 Resume CTA branch-deletion (`git branch --list` shell exec, master spec tags v1.1) / C-9 YouNowMeeting enrichment (substrate) / C-10 N-active count CTA (substrate deriver or list expansion) / C-13 TeammateMatch.durationSec hardcoded 0 (substrate) / C-14 InboxBlock SQL re-fetch debounce (cardinality threshold not yet reached) / C-16 InboxItem.sourceURL nil for D3 (substrate enrichment) / C-20 WHERE STOPPED Line 2 last-commit (substrate query) / C-21 WHERE STOPPED file path:line (substrate payload allow-list extension) / C-23 Analytics surface real content (substrate + design) / C-24 InsightsSnapshot.recentActivity orphan drop (LeafMCP coupling).

**Phase 5.6 deferred (1 carry):** C-11 offline / stale footer (relay status plumbing).

**Track-9 localization deferred (1 carry):** C-12 row tap → Team teammate detail + C-15 RouteCoordinator.openURL + C-19 severityWord English literal — all Track-9 candidates.

**Polish scope only:** No new features, no behavioral changes beyond the 6 carries, no event-kind additions.

---

## 2. Architecture

Three sub-trees touched:

| Layer | What's added | What's modified |
|---|---|---|
| **LeafCore** | `Home/HomeRelativeTimeFormatter.swift` (≤80 LOC, 1 public API) / `Home/InboxFiltering.swift` (≤60 LOC, 1 public API) + matching test files | None |
| **View layer** | None | `TodayBlock.swift` (C-3 + C-4), `YouNowBlock.swift` (C-7 + C-22 callsite), `InboxBlock.swift` (C-18 + C-22 callsite via InboxFiltering), `WithYouOnThisBlock.swift` (C-22 callsite), `WhereStoppedBlock.swift` (C-22 callsite) |
| **Documentation** | `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment.md` (Track-9 stub) | `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` (§9.1 carry annotation pass) |

Public APIs of new helpers are deliberately minimal to avoid premature abstraction (per CLAUDE.md "don't add features beyond what the task requires"):

```swift
// LeafCore/Home/HomeRelativeTimeFormatter.swift
public enum HomeRelativeTimeFormatter {
    /// Returns a bucketed relative-time string: "now" / "Nm ago" / "Nh ago" / "yesterday" / "N days ago" / absolute "MMM d".
    /// - Parameter deltaMs: positive milliseconds elapsed (nowMs - eventMs); clock-skew protected via `max(0,…)`.
    public static func format(deltaMs: Int64, nowMs: Int64) -> String
}

// LeafCore/Home/InboxFiltering.swift
public enum InboxFiltering {
    /// Filter and search InboxItems against a filter chip + free-text query.
    /// - filter: `.all` returns all items; otherwise items matching the kind.
    /// - query: empty string → no text filter. Non-empty → case-insensitive substring against `title OR sourceMeta`, whitespace-trimmed.
    public static func filtered(items: [InboxItem], filter: InboxFilter, query: String) -> [InboxItem]
}
```

Neither helper holds state; both are pure functions over value types — directly unit-testable without SwiftUI.

---

## 3. Per-carry implementation

### 3.1 C-22 — `HomeRelativeTimeFormatter` unification

**Current state** (3 sites with divergent shapes):

| File | Signature | Buckets |
|---|---|---|
| `Leaf/Views/Window/Home/Blocks/WhereStoppedBlock.swift:98-107` | `formatRelative(_ deltaMs:Int64, nowMs:Int64) -> String` (static private) | `now` / `Nm ago` / `Nh ago` / `yesterday` / `N days ago` / absolute `MMM d` |
| `Leaf/Views/Window/Home/Blocks/WithYouOnThisBlock.swift:185-194` | `formatRelative(msAgo ms:Int64) -> String` (instance private) | `Ns` / `Nm` / `Nh` / `Nd` (no "ago" suffix, simpler) |
| `Leaf/Views/Window/Home/Blocks/YouNowBlock.swift:256-260` | `formatRelative(msAgo:Int64) -> String` (instance private) | wraps "X ago" string |

**Resolution.** Adopt the **WhereStoppedBlock bucket ladder** as canonical (most detailed, locale-deterministic) and migrate all 3 callsites. Bucket spec:

- `delta < 60s` → `"now"`
- `60s ≤ delta < 60min` → `"\(min)m ago"`
- `60min ≤ delta < 24h` → `"\(hr)h ago"`
- `24h ≤ delta < 48h` AND same calendar day-minus-1 in user locale → `"yesterday"`
- `48h ≤ delta < 7d` → `"\(days) days ago"`
- `delta ≥ 7d` → absolute `MMM d` via cached `en_US_POSIX DateFormatter("MMM d")`

Implementation file:

```swift
// Packages/LeafCore/Sources/LeafCore/Home/HomeRelativeTimeFormatter.swift
import Foundation

public enum HomeRelativeTimeFormatter {
    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    public static func format(deltaMs: Int64, nowMs: Int64) -> String {
        let delta = max(0, deltaMs)
        let seconds = delta / 1000
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 2 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let eventMs = nowMs - delta
        return absoluteFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(eventMs) / 1000))
    }
}
```

**Callsite migration semantics.** Two of the three callsites (`WithYouOnThisBlock`, `YouNowBlock`) currently pass `msAgo` (a single Int64 already representing the delta) rather than `(delta, now)`. Migration computes `nowMs` inline via `Int64(Date().timeIntervalSince1970 * 1000)` at the call boundary — caller-side trivial. This intentionally **changes the WithYou and YouNow bucket output strings** (simpler "s / m / h / d" → richer "now / Nm ago / Nh ago / yesterday / N days ago / MMM d"). Acceptable per master spec §4.3 + §3.4 — both blocks render relative timestamps; richer wording matches WhereStoppedBlock voice and master spec mockups. Manual smoke spot-checks new wording for visual parity.

**Tests** (`Packages/LeafCore/Tests/LeafCoreTests/HomeRelativeTimeFormatterTests.swift`, 8 cases):

1. `delta = 30s` → `"now"`
2. `delta = 5min` → `"5m ago"`
3. `delta = 3h` → `"3h ago"`
4. `delta = 30h` → `"yesterday"`
5. `delta = 4d` → `"4 days ago"`
6. `delta = 14d, nowMs = 2026-05-19 00:00 UTC ms` → `"May 5"`
7. `delta = -500ms (clock skew)` → `"now"` (clock-skew guard)
8. `delta = 0` → `"now"`

### 3.2 C-17 — `InboxFiltering` extraction + unit tests

**Current state** (`Leaf/Views/Window/Home/Blocks/InboxBlock.swift:46-54`):

```swift
private var filteredItems: [InboxItem] {
    let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let byFilter = selectedFilter == .all ? items : items.filter { $0.kind == selectedFilter.kind }
    guard !trimmedQuery.isEmpty else { return byFilter }
    return byFilter.filter { item in
        item.title.lowercased().contains(trimmedQuery)
            || item.sourceMeta.lowercased().contains(trimmedQuery)
    }
}
```

**Resolution.** Extract logic to LeafCore as pure function over `[InboxItem]`, replace InboxBlock body to call helper. Implementation:

```swift
// Packages/LeafCore/Sources/LeafCore/Home/InboxFiltering.swift
import Foundation

public enum InboxFiltering {
    public static func filtered(items: [InboxItem], filter: InboxFilter, query: String) -> [InboxItem] {
        let byFilter = items.filter { filter.admits($0.kind) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return byFilter }
        return byFilter.filter { item in
            item.title.lowercased().contains(trimmed)
                || item.sourceMeta.lowercased().contains(trimmed)
        }
    }
}
```

Uses existing `InboxFilter.admits(_ kind: InboxKind) -> Bool` predicate (`Packages/LeafCore/Sources/LeafCore/Insights/InboxItem.swift:57`). No new property additions on InboxFilter.

**Tests** (`Packages/LeafCore/Tests/LeafCoreTests/InboxFilteringTests.swift`, 10 cases):

1. Empty items + empty query + `.all` → empty
2. Items + empty query + `.all` → all items (order preserved)
3. Items + empty query + `.reviews` → only `.reviewRequest` kind
4. Items + empty query + `.questions` → only `.openQuestion` kind
5. Items + empty query + `.mentions` → only `.mention` kind
6. Items + `"review"` query + `.all` → items where `title` contains "review" (case-insensitive)
7. Items + `"REVIEW"` query + `.all` → same as case 6 (case-insensitive sanity)
8. Items + `"  spaces  "` query + `.all` → whitespace-trimmed match
9. Items + `"meta-only"` query + `.all` → match against `sourceMeta`, not just `title`
10. Items + `"foo"` query + `.reviews` → AND combination (`.reviews` filter ∧ "foo" substring)

### 3.3 C-3 — TodayBlock narrow-window ViewThatFits fallback

**Current state.** `TodayBlock.metricsRow` renders 4 cells in a fixed `HStack(alignment: .top, spacing: LeafSpace.lg)` via local `metricCell(value:label:)` helper — focused, AI ratio, sessions, commits — with trailing `Spacer(minLength: 0)`. (`TodayMetrics.switchCount` exists in substrate but isn't rendered as a cell today — out of P9 scope, separate carry candidate). At popover width ≤ 520pt the row clips.

**Resolution.** Wrap the metrics `HStack` in `ViewThatFits` with two branches — wide horizontal (current shape) and narrow 2×2 grid (no expand state needed):

```swift
private var metricsRow: some View {
    ViewThatFits(in: .horizontal) {
        // Wide branch — 4 cells horizontal (current shape)
        HStack(alignment: .top, spacing: LeafSpace.lg) {
            metricCell(value: focusValue, label: "focused")
            metricCell(value: aiRatioValue, label: "AI ratio")
            metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
            metricCell(value: "\(metrics.commitsCount)", label: "commits")
            Spacer(minLength: 0)
        }
        // Narrow branch — 2×2 grid
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            HStack(alignment: .top, spacing: LeafSpace.lg) {
                metricCell(value: focusValue, label: "focused")
                metricCell(value: aiRatioValue, label: "AI ratio")
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: LeafSpace.lg) {
                metricCell(value: "\(metrics.sessionsCount)", label: "sessions")
                metricCell(value: "\(metrics.commitsCount)", label: "commits")
                Spacer(minLength: 0)
            }
        }
    }
}
```

No new `@State` (vs alternate "expand to show" pattern); grid renders all 4 cells always. Cells reused via existing private `metricCell` helper. Reading order preserved (focused → AI ratio → sessions → commits) for VoiceOver narrate consistency.

**Threshold.** `ViewThatFits` measures intrinsic content width. Picks the first branch that fits; falls through to narrow when wide overflows.

**Test.** No unit test for ViewThatFits selection (SwiftUI internal). Manual smoke at multiple popover widths (480 / 560 / 720 / 1024pt).

### 3.4 C-4 — TodayBlock DateFormatter cache

**Current state** (TodayBlock.swift:49):

```swift
private var sectionLabel: String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter.string(from: Date())
}
```

`DateFormatter()` allocated per body re-eval — wasted work on every snapshot change.

**Resolution.** Hoist to `private static let`:

```swift
private static let sectionDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f
}()

private var sectionLabel: String {
    Self.sectionDateFormatter.string(from: Date())
}
```

Note: `setLocalizedDateFormatFromTemplate` is locale-aware. Static cache picks up user locale at first access and stays bound to that locale for the app lifetime — acceptable per master spec §9.1 C-4 ("locale-aware, so cache by locale or accept en_US-only"). User locale changes mid-session require app relaunch to refresh — known limitation, low-impact for "TODAY · May 19" label.

**Test.** No new test (perf change, observable behavior unchanged for the same locale).

### 3.5 C-7 — YouNowBlock Button wrap on `.away`

**Current state** (`Leaf/Views/Window/Home/Blocks/YouNowBlock.swift:108-129`):

```swift
private var awayContent: some View {
    VStack(alignment: .leading, spacing: LeafSpace.md) {
        … // away row content
    }
    .contentShape(Rectangle())  // (line 37) — modifier applied on the LeafCard wrapper
}

// Outer modifier (line ~37 in body):
.contentShape(Rectangle())
.onTapGesture { handleTap() }
.modifier(YouNowTapModifier(state: state))  // gates tap to .away only
```

**Resolution.** Replace the `.contentShape + .onTapGesture + YouNowTapModifier` triad with a proper `Button` wrap on the `.away` branch only. Other branches (`.active` / `.inMeeting` / `.deepWorkFocus`) remain visually identical but non-tappable (current behavior preserved).

```swift
switch state {
case .away(let away):
    Button(action: { handleResumeCTA(away) }) {
        awayContent(away)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(resumeCTAA11yLabel(away))
    .accessibilityHint("Opens \(away.lastApp ?? "the last active app")")
case .active(let active):
    activeContent(active)   // non-tappable, unchanged
case .inMeeting(let meeting):
    inMeetingContent(meeting)
case .deepWorkFocus(let focus):
    deepWorkFocusContent(focus)
}
```

`buttonStyle(.plain)` preserves the visual styling — no system-Button chrome added. The existing `YouNowTapModifier` becomes obsolete and is deleted. Existing `Resume CTA` inner Button (lines 225-234) remains as-is — nested `Button { Button { } }` in SwiftUI works as expected when the outer uses `.plain` style and the inner has explicit `.contentShape` for hit-testing.

Actually — to avoid the nested-button anti-pattern, the simpler shape: wrap the whole `.away` card in Button when no Resume CTA shows; when Resume CTA shows, the inner Resume button takes precedence and the outer remains tappable for the card body. Decision deferred to T4 implementation; both shapes are spec-compliant.

**Test.** A11y trait verification is awkward to unit-test (SwiftUI internal). Manual smoke verifies VoiceOver announces "Button" + label on `.away` row. Visual regression spot-check during manual smoke confirms tap behavior unchanged.

### 3.6 C-18 — InboxBlock empty vs no-match icon differentiation

**Current state** (`Leaf/Views/Window/Home/Blocks/InboxBlock.swift:57-75`):

```swift
private var emptyDataState: some View {
    LeafEmptyState(icon: LeafIcons.brand.leaf, title: "All clear.", description: "...")
}

private var noMatchState: some View {
    LeafEmptyState(icon: LeafIcons.brand.leaf, title: "No matches.", description: "...")
    // + "Clear filters" CTA below
}
```

Both render `LeafIcons.brand.leaf`. Semantically distinct (positive "achievement" vs neutral "search miss") but visually identical.

**Resolution.** Swap `noMatchState` icon to `LeafIcons.nav.searchSF` (`"magnifyingglass"` SF Symbol — confirmed present in `Leaf/Theme/Primitives/LeafIcons.swift:42`). Empty stays on the leaf brand icon (positive scan).

```swift
private var noMatchState: some View {
    LeafEmptyState(icon: LeafIcons.nav.searchSF, title: "No matches.", description: "Try adjusting your filters or search.")
    // + "Clear filters" CTA below
}
```

**Test.** No unit test (visual change). Manual smoke verifies both states render distinct icons.

---

## 4. Sweeps

Three sweeps execute **after** the 6 carry resolutions (which establish the polished baseline):

### 4.1 HIG manual sweep (T6)

Scope: 7 Home block files + `HomeView.swift`. Checklist per file:

- Touch targets ≥ 44×44pt (LeafCard whole-card tap, button hit areas)
- Token-only fidelity (no raw `Color.something` / `.font(.system(...))` / `CGFloat` literals — all via `LeafType` / `LeafSpace` / `LeafColors`)
- Padding consistency via `LeafSpace.{sm,md,lg,xl}` only
- Card hierarchy follows macOS HIG (single elevation tier on Home, no nested shadows)
- Accent color used only for semantic emphasis (avoid decorative accent)

Inline fixes ≤ 30 LoC per finding. Larger findings → Track-9 carry (append to stub).

### 4.2 A11y subagent audit (T7)

Spawn `hig` skill subagent (Apple HIG focus, macOS-aware) with prompt:

> Audit accessibility compliance on these 7 Home block files for macOS VoiceOver, keyboard navigation, focus order, Dynamic Type, and Reduce Motion. Report per-file findings with file:line refs and severity (BLOCKER / IMPORTANT / NIT). Specifically check: missing `.accessibilityLabel` on tappable rows, missing `.accessibilityHint` on actionable elements, `.accessibilityAddTraits([.isButton])` on Button-wrapped rows, focus order matching visual order, animations gated by `value:` param (Reduce Motion compliance), Dynamic Type min/max bounds on LeafType usage. Files: [list].

Audit deliverable: structured findings list. Triage:
- BLOCKER / IMPORTANT view-level → inline fix in T7 commit
- Substrate-touching → Track-9 carry
- NIT → either inline if trivial or Track-9 carry

### 4.3 Perf manual review (T8)

Scope: code-level review of Home blocks (no Instruments per P5 precedent — Track-7 §10 acceptance). Checklist:

- DateFormatter / NumberFormatter / RelativeDateTimeFormatter allocations — verify all are `static let` cached (C-4 covers TodayBlock; sweep verifies YouNow + WhereStop + WithYou)
- Equatable correctness on snapshot structs — non-trivial `[InboxItem]` / `[TeammateMatch]` arrays should drive animation `value:` correctly (cross-fade triggers on real change, not identity churn)
- `ForEach` IDs — must use opaque stable IDs (memberID / item.id), never `\.indices` or hash
- Animation `value:` parameters — match the Equatable struct that actually changes (P3..P7 ship Equatable correct; verify)
- LeafCard padding/shadow cost — bounded by `prefix(5)` cap on InboxBlock + WithYouOnThisBlock rows; no concern at typical cardinality

Inline fixes ≤ 30 LoC. Larger → Track-9 carry.

### 4.4 Manual smoke (T9) — Track-8 wrap golden path

Spot-checks per Phase 8.3..8.8 specs §10. I launch Debug build via `open <DerivedData>/Leaf.app`, take initial screenshot, then user drives clicks. Per memory `feedback_ui_smoke_user_drives.md`.

| Phase | Spot-check | Expected behavior |
|---|---|---|
| P3 TODAY | 4 metric cells (focused / AI ratio / sessions / commits) render with values; pill strip with `+N` expand; empty state when no data | LeafCard + LeafPill render; ViewThatFits 4-wide ↔ 2×2 grid fallback at narrow widths |
| P4 YOU·NOW | Active state shows app + context label + intensity bars; Away state shows Resume CTA tappable to relaunch app | Manual lock-screen test or wait for idle > 30 min for Away transition |
| P5 WITH YOU | Empty state shows "→ Team" CTA; populated rows show avatar + confidence badge + relative time | Tap row → routes to Team tab via `windowState.section = .team` |
| P6 INBOX | Search field + 4 filter chips + scrollable list; row tap → external URL via NSWorkspace; no-match icon distinct from empty | "Clear filters" CTA in no-match state; empty state has no CTA |
| P7 WHERE STOPPED | Header + excerpt + WIP signals chips; tap routes to `WorkStateDetailScreen`; empty state for fresh DB | Animation cross-fade on snapshot change |
| P8 ANALYTICS | Analytics tab renders LeafEmptyState placeholder ("Analytics view coming soon"); icon is `leaf-nav-analytics` SVG | No data fetching; static placeholder |

Findings handling: pure polish ≤ 30 LoC → inline fix; substrate-touching → new Track-9 carry append.

---

## 5. Track-9 spec stub (T10)

New file: `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment.md`.

Placeholder content (not a brainstormed design — that happens in a separate session with fresh context):

```markdown
# Track-9 — Substrate enrichment (post-Track-8)

**Status:** STUB. Brainstorm pending in a separate session.
**Source:** Track-8 master spec §9.1 carry-overs unresolved after P9 wrap.

## Carry inventory (14 carries + 1 Phase 5.6 dependency)

### Theme A — YOU·NOW depth (3 carries)
- C-5 LocalAppsStore reactivity (app-root env injection)
- C-6 inMeeting `ical://` deep-link
- C-9 YouNowMeeting substrate enrichment (title / endsAtMs / source.both merge)
- Plus current-state Track-9 paragraph: git polling deriver (branch + LinearID), intensity bars (Input Monitoring TCC), label tweak, .away/.deepWorkFocus enrichment

### Theme B — Empty state + presence enrichment (2 carries)
- C-10 N-active count CTA
- C-13 TeammateMatch.durationSec hardcoded 0

### Theme C — Route + URL plumbing (3 carries)
- C-12 Team teammate detail screen + RouteCoordinator.pushTeam(memberID:)
- C-15 RouteCoordinator.openURL extraction
- C-16 InboxItem.sourceURL for D3-derived items

### Theme D — WHERE STOPPED enrichment (2 carries)
- C-20 Line 2 dedicated last-commit subject (substrate query)
- C-21 anchorEventId → file path:line (collector payload allow-list)

### Theme E — Analytics surface (2 carries)
- C-23 Real Analytics content (weeklyMetrics deriver + chart + streaks + WoW)
- C-24 InsightsSnapshot.recentActivity orphan drop

### Theme F — Reader state machine (2 carries)
- C-1 Hybrid surface pills (Layer B emission gap + SurfacePill shape)
- C-2 Error-state last-known snapshot retention

### Theme G — InboxBlock SQL re-fetch (1 carry)
- C-14 Debounce + SQL re-fetch when cardinality > 1000

### Theme H — Localization track (1 carry)
- C-19 severityWord English literal (plus broader Localizable.strings extraction)

### Phase 5.6 dependency (1 carry)
- C-11 WithYouOnThisBlock offline / stale footer (relay status plumbing)

### v1.1 deferred
- C-8 Resume CTA branch-deletion staleness (master spec tags v1.1)

## Next step

Spec written via `superpowers:brainstorming` skill in a new session with full Discovery pass over Theme A-H surfaces. Track-9 is multi-phase (likely T1..T8 mirroring theme split).
```

This stub is informational only — it does not commit to design decisions or implementation order.

---

## 6. Master spec §9.1 annotation (T11)

Edit `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` §9.1 with status tags. Pattern per carry:

- **C-3** → `**[RESOLVED P9 — see commit `<sha>`]**` prepended to summary
- **C-4** → same
- **C-7** → same
- **C-17** → same
- **C-18** → same
- **C-22** → same
- Other 18 carries → `**[DEFERRED → Track-9 stub `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment.md`]**` prepended

No bulk rewrites — minimal annotation pass for forward-traceability.

---

## 7. Tests

### 7.1 New tests

- `HomeRelativeTimeFormatterTests.swift` — 8 cases (§3.1 ladder)
- `InboxFilteringTests.swift` — 10 cases (§3.2 contract)
- Total net new: **18 XCTest**

### 7.2 Baseline + target

| Metric | Baseline (post-P8) | Target (post-P9) | Delta |
|---|---|---|---|
| XCTest | 2778 | **≥ 2796** | +18 |
| Swift-Testing | 45 | 45 | 0 |
| **Total** | **2823** | **≥ 2841** | **+18** |
| Failures | 0 | 0 | — |
| Skipped | 4 | 4 | — |

(Original target 2843 revised down: C-8 dropped → 2 fewer Resume CTA staleness tests.)

### 7.3 Test discipline

TDD per carry helper: write test first → red → implement → green → commit. Stage 5 T1 (HomeRelativeTimeFormatter) and T2 (InboxFiltering) each have 2 commits: `test(...)` (red) followed by `feat(...)` (green).

---

## 8. Acceptance criteria

| AC | Description | Verification |
|---|---|---|
| AC-1 | C-3 resolved — TodayBlock uses ViewThatFits with 4-cell wide / 2×2 narrow grid branches | Visual smoke at 480 / 560 / 720 / 1024pt |
| AC-2 | C-4 resolved — TodayBlock.sectionLabel uses `static let` cached DateFormatter | Grep `static let.*DateFormatter` in TodayBlock.swift |
| AC-3 | C-7 resolved — YouNowBlock `.away` uses `.contentShape + .onTapGesture + .accessibilityAction(named: "Resume")` per OQ-P9-1 (outer Button wrap reverted to avoid nested-Button conflict with inner Resume CTA Button); YouNowTapModifier kept | Grep `accessibilityAction.*Resume` in YouNowBlock.swift; YouNowTapModifier private struct retained |
| AC-4 | C-17 resolved — InboxFiltering.filtered extracted to LeafCore; InboxBlock.filteredItems delegates to it; 10 new XCTest pass | `xcodebuild test -scheme LeafCore` includes `InboxFilteringTests` |
| AC-5 | C-18 resolved — InboxBlock noMatchState uses `LeafIcons.nav.searchSF`; emptyDataState keeps `LeafIcons.brand.leaf` | Grep both icon usages in InboxBlock.swift |
| AC-6 | C-22 resolved — HomeRelativeTimeFormatter.format used in all 3 prior callsites; per-block formatRelative bodies delegate to the shared helper (thin wrappers preserved in WithYouOnThisBlock + YouNowBlock to minimise callsite diff, full inline replacement in WhereStoppedBlock) | Grep `HomeRelativeTimeFormatter.format` in `Leaf/Views/Window/Home/Blocks/` returns ≥ 3 hits; remaining `formatRelative` wrappers all delegate to the shared helper |
| AC-7 | HIG sweep findings triaged — inline fix count + Track-9 carry count reported in T6 commit body | Commit message |
| AC-8 | A11y subagent audit findings triaged — same accounting in T7 commit body | Commit message |
| AC-9 | Perf manual review findings triaged — same accounting in T8 commit body | Commit message |
| AC-10 | Manual smoke 6 phases (P3..P8) — all golden-path checks pass | T9 commit body documents result |
| AC-11 | Track-9 spec stub created at `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment.md` | File exists with §1.. inventory of 14 carries |
| AC-12 | Master spec §9.1 annotated — 6 carries marked `[RESOLVED P9 — commit <sha>]`; remaining 18 marked `[DEFERRED → Track-9 stub]` | Spec file diff |
| AC-13 | Zero new SQLCipher migrations | `git diff feature/phase-8-1-substrate -- Packages/LeafCore/Sources/LeafCore/DB/` empty |
| AC-14 | Zero new event_kinds / MCP tools / ShareEventTypeKey delta | `git diff … Packages/LeafCore/Sources/LeafCore/Privacy/ShareEventTypeKey.swift` empty; `git diff … LeafMCP/` empty |
| AC-15 | Privacy walkback grep — 0 hits for forbidden fields in P9 file scope | `grep -nE "absolute_path\|full_comment_body\|raw_email\|notes_body\|email_subject\|note_body\|file_contents\|raw_prompt\|tool_input\|tool_response\|response_body" <P9 files>` |
| AC-16 | `just check-tokens` 3-tier clean (BASE + MIGRATION + RETIRED) | CI runs locally green |
| AC-17 | 5/5 xcodebuild schemes Debug build SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP) | `xcodebuild build` each scheme |
| AC-18 | SPM tests ≥ 2841 total (2796+ XCTest + 45 Swift-Testing), 0 failures, ≤ 4 skipped | `swift test` |
| AC-19 | HomeView.swift LOC ≤ 280 (P3 budget) | `wc -l Leaf/Views/Window/Home/HomeView.swift` |
| AC-20 | New helper file LOC ≤ 80 each (HomeRelativeTimeFormatter ≤ 80, InboxFiltering ≤ 60) | `wc -l` |

---

## 9. Risks & open questions

| ID | Concern | Mitigation |
|---|---|---|
| R-1 | ViewThatFits 5↔3 cell selection may flicker on narrow-window resize at the boundary | Test at boundary widths; if flickering observed, add explicit fixed cutoff via GeometryReader as fallback (Track-9 carry) |
| R-2 | YOU·NOW Button wrap may break existing tap-test or visual layout (extra Button chrome) | `.buttonStyle(.plain)` preserves visual; manual smoke verifies. Fallback: keep `contentShape + onTapGesture + .accessibilityAddTraits(.isButton)` (simpler, no Button wrap) |
| R-3 | Migrating WithYou / YouNow callsites to HomeRelativeTimeFormatter changes user-visible wording ("5m" → "5m ago", "3d" → "3 days ago") | Acceptable — richer wording matches WhereStopped voice + master spec §4.3 mockups. Documented in §3.1 |
| R-4 | InboxFiltering extraction requires `InboxFilter.kind` property | Verify presence in T2 implementation; if absent, add single computed property in same commit |
| R-5 | A11y subagent may surface findings that require substrate touches (carry list grows) | Triage discipline: only inline if ≤ 30 LoC pure view; else Track-9 carry |
| OQ-P9-1 | Resume CTA inner Button + outer .away Button — nested-button anti-pattern? | T4 decision: either keep nested with `.buttonStyle(.plain)` outer, or keep `.contentShape + onTapGesture` outer + `.accessibilityAddTraits([.isButton])`. Both spec-compliant. Document choice in T4 commit |
| OQ-P9-2 | Smoke findings that are pure polish but exceed 30 LoC — inline or Track-9? | Default Track-9 (avoid scope creep). Inline only if blocker for ship |

---

## 10. Files touched

**New:**
- `Packages/LeafCore/Sources/LeafCore/Home/HomeRelativeTimeFormatter.swift`
- `Packages/LeafCore/Sources/LeafCore/Home/InboxFiltering.swift`
- `Packages/LeafCore/Tests/LeafCoreTests/HomeRelativeTimeFormatterTests.swift`
- `Packages/LeafCore/Tests/LeafCoreTests/InboxFilteringTests.swift`
- `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment.md` (stub)

**Modified:**
- `Leaf/Views/Window/Home/Blocks/TodayBlock.swift` (C-3 ViewThatFits + C-4 DateFormatter cache)
- `Leaf/Views/Window/Home/Blocks/YouNowBlock.swift` (C-7 Button wrap + C-22 callsite)
- `Leaf/Views/Window/Home/Blocks/InboxBlock.swift` (C-18 icon + InboxFiltering wire-up)
- `Leaf/Views/Window/Home/Blocks/WithYouOnThisBlock.swift` (C-22 callsite)
- `Leaf/Views/Window/Home/Blocks/WhereStoppedBlock.swift` (C-22 callsite)
- `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` (§9.1 annotation pass)
- `.claude/shared/current-state.md` (final landing commit)

**Deleted (T4 cleanup):**
- `YouNowTapModifier` private struct inside `YouNowBlock.swift` (lines ~321-) becomes obsolete after C-7 Button wrap. Removed inline (not a separate file).

---

## 11. References

- Master spec: `docs/superpowers/specs/2026-05-18-track-8-home-ux-design.md` (§9 phasing + §9.1 carry backlog + §10 acceptance)
- Predecessor phases: 8.3 / 8.4 / 8.5 / 8.6 / 8.7 / 8.8 specs in `docs/superpowers/specs/`
- Conventions: `.claude/shared/conventions.md` "Одна phase = одна сессия" 8-stage workflow
- Skills used: `superpowers:brainstorming` (Stage 2) / `superpowers:writing-plans` (Stage 4) / `superpowers:test-driven-development` (Stage 5) / `hig` (Stage 5 T7 a11y subagent) / `superpowers:requesting-code-review` + `superpowers:code-reviewer` subagent (Stage 6) / `superpowers:receiving-code-review` (Stage 6) / `superpowers:verification-before-completion` (Stage 7)
