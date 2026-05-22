# Track-10 T4 — NEEDS YOU rename + scope tighten phase spec

**Status**: Stage 3 (per-phase spec) closed. Authored 2026-05-22 from approved
Stage 4 plan `~/.claude/plans/track-10-t4-needs-purrfect-sky.md` after
Stages 1-2 brainstorm (Q1..Q8 closed + Q9 fence-read) + Stage 4.5 CTO
meta-review (3 passes, 23 findings dispositioned: 2 CRITICAL inline-fixed,
5 HIGH inline-fixed/dispositioned, rest MEDIUM/LOW dispositioned). Stages
5-8 (implementation / review / verification / ship) landed in the same
calendar day; this spec is the post-implementation source of truth.

**Branch**: `feature/track-10-operational-home`. Pre-flight housekeeping
merge `8408574b` brought `feature/track-10-T2-5-operational-followup`
(T2.5 + dev-launch-reliability infra) into operational-home tip
`77f75c73` so T4 implementation lands on top of every T2.5 fix.

**Master spec contract**: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` — §4 T4 · §3.3 · §5.8 · §6 · §7.2.

**Precedent specs**:
- T2.5 follow-up (housekeeping merge baseline): `docs/superpowers/specs/2026-05-22-track-10-T2-5-operational-followup.md`.
- T3 inline badge (pure-UI-refactor precedent): `docs/superpowers/specs/2026-05-22-track-10-T3-younow-badge.md`.

---

## 1. Goal

Reshape the bottom-of-Home INBOX block into an operational **NEEDS YOU**
surface. Track-8 INBOX surface read as a 14-kind firehose; Track-10 T4
defaults Home to a 7-kind "needs YOUR response NOW" subset and keeps
the `[All]` chip as the escape hatch for the 7 dropped informational
kinds (commentOnMyWork / calInviteDeclined / calUpcoming15min /
calConflict / mailUnreadBucket / reminderDueToday / slackDM).

T4 is a **pure UI refactor + enum-case addition**:

- 0 new event_kinds (registry frozen at 198).
- 0 new SQLCipher migrations (30 tables preserved).
- 0 new MCP tools (15 frozen).
- 0 new `ShareEventTypeKey` entries.
- 0 new payload reads → T4 is sentinel-injection EXEMPT per master spec §6.
- LeafCore types `InboxFilter` / `InboxKind` / `InboxItem` / `InboxFiltering`
  retain `Inbox*` naming — substrate-tier (consumed by MCP tools + tests
  + ProdInsights moat) where "inbox" reads fine as internal vocabulary.
  Only the UI surface IS rename-scoped.

Net diff: 7 files / +158 / −30 LOC across 4 implementation commits + 1
fix-bundle. View-file renames detected by git at 78% / 81% / 90%
similarity.

---

## 2. Brainstorm decisions

| Q | Decision |
|---|---|
| Q1 `.actionable.admits(_:)` matrix | 7-kind whitelist: `reviewRequest` · `mention` · `openQuestion` · `blocker` · `buildFailed` · `ciFailed` · `liveMeeting`. 7 dropped per §1. |
| Q2 Enum case position | Position #2 after `.all`: `.all / .actionable / .reviews / .questions / .mentions / .alerts`. `rawValue == "actionable"`. |
| Q3 Count badge rendering | Inline suffix in chip title: `"NEEDS YOU · 3"` / `"All · 12"`. Zero `LeafPill` primitive change. |
| Q4 Empty-state copy | Title-only `"Nothing waiting on you right now."`, `description: nil`. Honest quiet — no secondary echo of admits matrix. |
| Q5 No-match-state CTA reset | `.actionable` + clear search. CTA label "Clear filters" preserved (carry C-T4-1 to T9 wrap if confusing). |
| Q6 Commit decomposition | 5 atomic + 1 review fix-bundle: C1 enum + tests · C2 chip strip · C3 NeedsYouBlock rename · C4 FilterRow + Row renames · review fix-bundle · C5 spec landing. |
| Q7 Test placement | Extend `InboxItemTests.swift` matrix (5×14 → 6×14) + `InboxFilteringTests.swift` fixtures (4 → 10 items, 7 admits + 3 dropped). No new test file. |
| Q8 Branch baseline | Housekeeping merge T2.5-followup into operational-home (non-FF) preserves T2.5 + dev-launch-reliability full history. T4 lands on the merged tip. |

---

## 3. Surface contract

### 3.1 InboxFilter enum extension

**File**: `Packages/LeafCore/Sources/LeafCore/Insights/InboxItem.swift`.

```swift
public enum InboxFilter: String, Equatable, Hashable, Sendable, CaseIterable {
    case all
    case actionable  // T4 — "needs YOUR response NOW" umbrella over 7 of 14 InboxKinds
    case reviews
    case questions
    case mentions
    case alerts
}
```

Extended `admits(_:)` uses an **exhaustive switch on InboxKind** for the
`.actionable` arm:

```swift
case .actionable:
    switch kind {
    case .reviewRequest, .mention, .openQuestion, .blocker,
         .buildFailed, .ciFailed, .liveMeeting:
        return true
    case .commentOnMyWork, .calInviteDeclined, .calUpcoming15min,
         .calConflict, .mailUnreadBucket, .reminderDueToday, .slackDM:
        return false
    }
```

Exhaustive switch is the **compile-time fence** — when a future phase
adds a 15th InboxKind, this switch errors out and forces explicit
triage. A silent `default: false` would be a privacy/UX regression.

### 3.2 NeedsYouBlock view

**Source file** (post-rename): `Leaf/Views/Window/Home/Blocks/NeedsYouBlock.swift`
(was `InboxBlock.swift`; 86 → 105 LOC).

- Struct `InboxBlock` → `NeedsYouBlock`.
- `@State selectedFilter: InboxFilter = .actionable` (was `.all`).
- Header text `"NEEDS YOU"` (was `"INBOX"`).
- Empty state collapses to title-only — `LeafEmptyState(icon:, title:)`
  invoked with defaulted `description: nil` / `ctaTitle: nil` / `onCTA: nil`.
- No-match-state CTA reset target: `selectedFilter = .actionable`
  (was `.all`).
- Private `counts(for items: [InboxItem]) -> [InboxFilter: Int]` helper
  **reuses** `InboxFiltering.filtered(items:filter:query:).count` per
  filter — not a separate `matches` extraction. This is the Pass 3
  CRITICAL H-1 fix: zero changes to
  `Packages/LeafCore/Sources/LeafCore/Home/InboxFiltering.swift`,
  substrate-purity invariant strict-preserved.

### 3.3 NeedsYouFilterRow chip strip

**Source file** (post-rename): `Leaf/Views/Window/Home/Blocks/NeedsYouFilterRow.swift`
(was `InboxFilterRow.swift`; 41 → 56 LOC).

- Struct `InboxFilterRow` → `NeedsYouFilterRow`.
- New `counts: [InboxFilter: Int]` parameter.
- Hand-rolled chip array with `(.actionable, "NEEDS YOU")` as the
  leading entry (6 total).
- Per-chip render `"\(chip.label) · \(count)"` as `LeafPill` title;
  count from the dict, `0` fallback for absent keys.
- A11y: `.accessibilityLabel("\(chip.label) filter, \(count) items")` +
  preserved `.isSelected` trait when `selected == chip.filter`.
- Token discipline preserved (LeafSpace.xs / LeafPill / Button.plain).

### 3.4 NeedsYouRow item renderer

**Source file** (post-rename): `Leaf/Views/Window/Home/Blocks/NeedsYouRow.swift`
(was `InboxItemRow.swift`; 89 LOC unchanged).

Struct `InboxItemRow` → `NeedsYouRow`. **Zero logic changes** — severity
dot + title + aggregation count + sourceMeta + tap-to-open URL + a11y
label preserved verbatim.

### 3.5 HomeView callsite

**File**: `Leaf/Views/Window/Home/HomeView.swift` (278 LOC, unchanged at
the LOC budget ceiling).

- Callsite `InboxBlock(items: snapshot.inboxItems)` →
  `NeedsYouBlock(items: snapshot.inboxItems)`.
- Block-list narrative comment refreshed: block 4 now reads
  "NEEDS YOU (full width — T4 from INBOX)".

LOC budget: 278 ≤ 310 (master spec §7.2 gate 6).

### 3.6 Test coverage

**InboxItemTests.swift** (69 → 110 LOC):

- `testInboxFilterValues` extended with `.actionable.rawValue == "actionable"`.
- `testInboxFilterAdmits_5FilterMatrix` renamed → `_6FilterMatrix`;
  added `.actionable` arm against 7-kind whitelist.
- New `testInboxFilter_actionable_rawValue_roundTrip` —
  `.actionable.rawValue == "actionable"` + `InboxFilter(rawValue:
  "actionable") == .actionable`.
- New `testInboxFilter_allCases_orderHasActionableSecond` —
  `.allCases == [.all, .actionable, .reviews, .questions, .mentions, .alerts]`
  position fence.

**InboxFilteringTests.swift** (108 → 160 LOC):

- New `actionableMixedFixtures` lazy var with 10 items (7 admits + 3
  sampled drops).
- `testFilterActionable_admitsSevenKinds_dropsThree`.
- `testFilterActionable_withQuery_intersectsAdmitsAndQuery` —
  query "build" ∩ `.actionable` = [a5].
- `testFilterActionable_allDropped_returnsEmpty`.
- Existing 4 fixture tests (`testFilteredAll_*` / `testFilterReviews_*`
  / etc.) **unchanged** — Track-9 P9 contract preserved.

### 3.7 Privacy walkback (T4 sentinel-injection EXEMPT)

Defensive grep over the 5 T4-touched files returns 0 hits across all
forbidden tokens. T4 reads zero new payload fields — `.actionable.admits`
operates on the `InboxKind` enum (atomic discriminator); count compute
filters by `kind` enum, never reads title / sourceMeta strings; filter
chip labels are static strings + a counted-integer suffix.

Track-9 T8 sentinel walkbacks (`RelayBodyLeakageTests` fence over
InboxItem fields) carry forward unchanged.

### 3.8 Substrate purity diff invariants

Verified against pre-merge tip `77f75c73`:

| Path | git diff line count |
|---|---|
| `Packages/LeafCore/Sources/LeafCore/DB/` | 0 |
| `Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` | 0 |
| `Packages/LeafCore/Sources/LeafCore/MCP/` | 0 |
| `Packages/LeafCore/Sources/LeafCore/Home/InboxFiltering.swift` | 0 |

ShareEventTypeKey registry case count: **198** (Track-6 baseline preserved).

ProdInsights+InboxItems (LeafCorePrivate moat) — untouched. Track-9 T8
feeders + `InboxSourceURLDeriver` unchanged.

### 3.9 Killed / renamed views inventory

| Action | Old | New | Similarity |
|---|---|---|---|
| Renamed | `Leaf/.../Blocks/InboxBlock.swift` (struct `InboxBlock`) | `Leaf/.../Blocks/NeedsYouBlock.swift` (struct `NeedsYouBlock`) | 78% |
| Renamed | `Leaf/.../Blocks/InboxFilterRow.swift` (struct `InboxFilterRow`) | `Leaf/.../Blocks/NeedsYouFilterRow.swift` (struct `NeedsYouFilterRow`) | 81% |
| Renamed | `Leaf/.../Blocks/InboxItemRow.swift` (struct `InboxItemRow`) | `Leaf/.../Blocks/NeedsYouRow.swift` (struct `NeedsYouRow`) | 90% |

All 3 file moves use `git mv` — rename detection green per
`git log --diff-filter=R --follow` for each path.

---

## 4. Implementation commits

5 atomic commits on `feature/track-10-operational-home`:

| Commit | Hash | Subject |
|---|---|---|
| Merge | `8408574b` | `merge: Track-10 T2.5 + dev-launch-reliability into operational-home` |
| C1 | `8ea71722` | `feat(track-10-T4): InboxFilter.actionable case + admits matrix + tests` |
| C2 | `eb753972` | `feat(track-10-T4): chip strip extension — leading [NEEDS YOU] + per-chip counts` |
| C3 | `46ce2957` | `feat(track-10-T4): NeedsYouBlock rename + default flip + header/empty/CTA + HomeView callsite` |
| C4 | `172c1135` | `feat(track-10-T4): NeedsYouFilterRow + NeedsYouRow renames + internal callsites` |
| Review fix | `e76f5e70` | `fix(track-10-T4): review pass — clean up think-aloud test comment` |
| C5 | _this commit_ | `docs(track-10-T4): SHIPPED — spec landing + current-state Track-10 entry` |

TDD discipline:

- **C1** wrote the matrix + roundtrip + order tests **first** — verified
  RED (`type 'InboxFilter' has no member 'actionable'`) — then added the
  enum case + admits arm — verified GREEN (61 tests passed in filter
  scope, including LeafCorePrivate `ProdInsightsInboxItemsTests` 34
  tests that consume `InboxKind` directly).
- **C2-C4** are view-tier; view-layer unit tests not yet adopted per
  Leaf precedent (Track-9 §9.3 C-43 carry). Verification via build +
  manual smoke per plan §3.6 + T3 precedent.

---

## 5. Stage 6 — independent review findings

`general-purpose` subagent ran over `8408574b..172c1135` (C1..C4
post-rename tip). 4 findings returned:

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | LOW / NIT | `InboxFilteringTests.swift` `testFilterActionable_withQuery_intersectsAdmitsAndQuery` docstring contained author "wait, no, let me recheck" exposition. | **FIXED INLINE** (commit `e76f5e70`) — replaced with single-line intent statement. |
| 2 | LOW / NIT | C1 commit message references spec file that doesn't exist yet on disk (lands in C5). | **SELF-RESOLVES in C5** — this commit. |
| 3 | LOW / NIT | `counts(for:)` calls `InboxFiltering.filtered` 6× per render (≤30×6 = 180 admit calls). | **DEFER** — already documented carry C-T4-2 in inline comment + plan §3.4. Profile only if narrow-Mac stutter surfaces. |
| 4 | INFO | Two documentary "originally Inbox*" header-comment anchors. | **ACCEPTABLE** per plan §5.2 G-4 (`git grep -- Leaf/ Packages/` scope; not type/symbol usage). |

Verdict: **APPROVE-WITH-NITS** — T4 ready to ship; 0 CRITICAL / 0 HIGH.

Substrate purity ✓ · privacy walkback ✓ · T2.5 fence ✓ · AC grep ✓ ·
HomeView LOC ✓ · `InboxFilter.actionable.admits` exhaustive switch ✓ ·
allCases order asserted ✓ · 25 selected tests passed ✓ ·
`NeedsYouBlock` defaults / header / empty / CTA / `counts(for:)` reuse
all match plan §3.4 ✓ · `NeedsYouFilterRow` chips / counts / a11y
`.isSelected` ✓ · `NeedsYouRow` logic preserved ✓.

A11y sub-review skipped per plan §8 TC-3 — chip selection trait
verified in main reviewer pass (`accessibilityAddTraits(.isSelected)`
present at NeedsYouFilterRow callsite).

---

## 6. Stage 7 — verification

Per master spec §7.2 invariants + T2.5 carry fences:

| # | Gate | Result |
|---|---|---|
| 1 | 5/5 Debug schemes (LeafCore + LeafCorePrivate + Leaf + LeafAgent + LeafMCP) | ✓ `just build-all` exit 0 |
| 2 | SPM tests green (incl. T2.5 fences) | ✓ DebugDiagnosticsTests 13/13 · ProdInsightsCurrentTaskIdentityTests 16/16 (T2.5 F3) · ProdInsightsTodayMetricsSwitchesTests 9/9 (T2.5 F1) · ProdInsightsInboxItemsTests 34/34 · InboxFilteringTests 14/14 · 6 new T4 tests all green. Pre-existing crash `ProdLinearGraphQLProviderTests.testWarmState_HappyPath_TrackD1` is T3 spec §6 carry, unrelated. |
| 3 | `just check-tokens` 3-tier clean (BASE+MIGRATION+RETIRED) | ✓ |
| 4 | Privacy walkback grep over 5 T4 files | ✓ 0 hits |
| 5 | Sentinel-injection regression test | ✓ EXEMPT per master spec §6 + plan §3.7; T2 sentinel test `test_gitDeltaReader_StripsWorkspacePathAndFilenamesFromSnapshot` continues to fence T2 producer surface unchanged. |
| 6 | HomeView.swift LOC ≤ 310 | ✓ 278 |
| 7 | `InsightsReader.refresh()` SQL call count monotonic | ✓ Unchanged (T4 adds zero pipeline calls; chip counts computed in-view via existing `InboxFiltering.filtered`). |
| 8 | No new SQLCipher migrations | ✓ DB/ diff 0 lines |
| 9 | No new ShareEventTypeKey entries | ✓ Registry case-line count still 198 + 0-line diff |

Plan §3.8 strict additions:

- ✓ `MCP/` 0-line diff
- ✓ `Home/InboxFiltering.swift` 0-line diff (substrate-purity strict)

T2.5 carry-fence smokes (plan §4.3 T2.5-I..M) — substrate tests green
per gate 2; manual smoke I..M is Дима driver (post-merge sanity).

Manual smoke A..H (plan §4.3) — Дима driver, post-merge; substrate
gates above cover compile-level correctness.

---

## 7. Carry-overs (post-T4)

These do NOT block T4 SHIPPED:

- **C-T4-1** — if T9 manual smoke surfaces "Clear filters" CTA-label vs
  `.actionable` reset-target semantic confusion, rename CTA to "Reset
  to default" or "Show NEEDS YOU".
- **C-T4-2** — profile `counts(for:items)` recompute under sustained
  typing; memoize via `@State`+`onChange(of: items)` if 60fps budget
  hit on low-end Macs.
- **C-T4-3** — if mid-state visual at C2 (INBOX header + NEEDS YOU
  chip) surfaces in any reviewer's screenshot, fold C2+C3 into a single
  combined commit on future similar refactors.
- **C-T4-4** — LeafCore type renaming (InboxFilter → NeedsYouFilter,
  InboxKind → NeedsYouKind, etc.) only if marketing demands "NEEDS YOU"
  as substrate concept.
- **C-T4-5** (T9 wrap) — a11y chip-strip selection trait audit (verified
  in this T4 pass but a sweep across Track-10 blocks is worthwhile).
- **C-T4-6** (post-Track-10) — view-layer unit tests adoption
  (Track-9 §9.3 C-43); once adopted, write `NeedsYouBlockTests`
  covering default filter + empty/no-match rendering.

---

## 8. References

- Master spec: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md`.
- T1 spec: `docs/superpowers/specs/2026-05-22-track-10-T1-foundation.md`.
- T2 spec: `docs/superpowers/specs/2026-05-22-track-10-T2-resume-hero.md`.
- T2.5 spec: `docs/superpowers/specs/2026-05-22-track-10-T2-5-operational-followup.md`.
- T3 spec: `docs/superpowers/specs/2026-05-22-track-10-T3-younow-badge.md`.
- Track-9 T8 spec (InboxKind 14-feeder substrate): `docs/superpowers/specs/2026-05-21-track-9-T8-inbox-feeder-expansion.md`.
- `.claude/shared/architecture.md` — substrate baseline (registry 198 · 30 SQLCipher tables · 15 MCP tools — unchanged through T4).
- `.claude/shared/conventions.md` — 8-stage per-phase workflow.
- ADR-010 walkback discipline — T2 sentinel-injection lineage; T4 EXEMPT.
