# Track-10 T6 — TEAM·N broader pulse phase spec

**Linear**: GUN-48
**Status**: SHIPPED 2026-05-23. Authored from approved Stage 4 plan
`~/.claude/plans/gun-48-track-10-t6-velvet-bengio.md` after Stages 1-2
brainstorm (Q1..Q10 closed) + Stage 4.5 CTO meta-review (2 passes, 11
findings — 0 outstanding CRITICAL/HIGH; all dispositioned inline + §11.A
stricter second pass added). Stages 5-8 (implementation / review /
verification / ship) landed in one session.

**Branch**: `feature/GUN-48-track-10-T6-team-n-broader-pulse` (off
`feature/track-10-operational-home` tip `a1fb09f9` = post-T5 SHIPPED +
conventions doc fix + GUN-47 fix-bundle).

**Master spec contract**: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` — §4 T6 · §3.4 · §5.4 · §6 · §7.2.

**Precedent specs**:
- T3 YouNowBadge inline (state-badge primitive deferral): `docs/superpowers/specs/2026-05-22-track-10-T3-younow-badge.md`.
- T5 SINCE YOU WERE LAST ACTIVE (defaulted-init 12th iteration · Stage 6 dual-review pattern · LEAF/GUN-NN discipline): `docs/superpowers/specs/2026-05-22-track-10-T5-since-last-active.md`.

---

## 1. Context

Track-10 T5 SHIPPED reshaped Home Zone-5 with the SINCE YOU WERE LAST
ACTIVE timeline. Zone-3 today holds NEEDS YOU (T4 SHIPPED) full-width and
a small WithYouOnThisBlock below it consuming `snapshot.sameTaskTeammates`
(Phase 8.5 substrate; narrow same-task match scope).

Track-9 wrap manual smoke surfaced two UX failures the narrow
WithYouOnThis block can't solve:
- Empty by default for solo / small teams (stub
  `recentTeammateSnapshots(maxAge:now:)` returns `[]`).
- Scope too narrow — user wants broader team radar (who's active right
  now), not just "who's on my exact Linear ID".

T6 replaces the narrow block with **TEAM·N broader pulse** — compact
teammate rows for everyone last-seen ≤ 15 min, with a conditional
empty-state CTA when org > 1 and reader returns `[]`, and the block hidden
entirely for solo users. Phase 5.4 will light up the DB-backed
`TeammatePresenceReader` against `presence_history`; T6 ships the surface
ready to consume that substrate.

T6 is **pure UI surface** plus minor substrate API additions for the
`memberCount` gate. Zero new event_kinds / migrations / MCP tools /
ShareEventTypeKey deltas. Registry frozen at 198. 30 SQLCipher tables
preserved. 15 MCP tools preserved.

---

## 2. Brainstorm decisions

| Q | Decision | Value |
|---|---|---|
| Q1 | Snapshot field naming + `sameTaskTeammates` disposition | **Surface-level drop + add** — remove `InsightsSnapshot.sameTaskTeammates` field + `InsightsReader.refresh()` call + `WithYouOnThisBlock.swift` + `HomeView` callsite. **Keep** `DerivedInsights.sameTaskTeammates(rule:)` protocol method + `SameTaskMatcher` deriver + tests + moat impl `ProdInsights+SameTaskTeammates.swift` as orphan library code (zero blast radius beyond surface). **Add** `activeTeammates: [TeammateSnapshot] = []` defaulted field + `recentTeammateSnapshots(maxAge:now:)` sequential call in `refresh()`. |
| Q2 | `TeammateSnapshot.youNowState` substrate touch | **B — NO substrate touch in T6.** Existing 7 fields suffice (memberID, displayName, linearID, branch, repo, currentApp, lastActivityAtMs). Row composition renders plain-text "active Nm ago" from `lastActivityAtMs`. Phase 5.4 owns `youNowState` field add + reader population atomically — when it lands, T6 row composition is patched to swap plain-text time → `YouNowStateBadge` reuse. Master spec §3.4 state-badge contract deferred to Phase 5.4. |
| Q3 | `OrgService.memberCount` accessor placement | **B — `InsightsSnapshot.memberCount: Int = 1` defaulted field** populated via new `OrgService.activeMemberCount() throws -> Int` accessor reading existing `database.readTeamMembers(orgID:, includeRemoved: false).count`. **No new Database SQL method needed** — `Database.readTeamMembers` already exists at line 841. Default `memberCount = 1` yields solo-user behavior in test fixtures without populating. |
| Q4 | Conditional rendering site | **HomeView orchestrates visibility, TeamNBlock orchestrates content.** HomeView Zone 3 reads `snapshot.memberCount > 1` → composes 2-col `ViewThatFits`; else single-column NeedsYouBlock at full width. TeamNBlock body handles `activeTeammates.isEmpty` → `LeafEmptyState` "Team presence sync coming soon." else rows. TeamNBlock has no `OrgService` knowledge — pure presentation. |
| Q5 | Zone 3 2-col layout | **B — `ViewThatFits`.** Wide → HStack 2-col (NEEDS YOU left, TEAM·N right, equal width). Narrow → VStack stacked (NEEDS YOU above TEAM·N full-width). Precedent — T3 narrow Grid fallback Stage 6 fix. |
| Q6 | Header `TEAM·N·active` semantic | **N = active teammates rendered** (last-seen ≤ 15 min count == visible-in-block count). Matches "NEEDS YOU · N" surface-count pattern. Avoids misleading "TEAM · 5 · active" with empty block body. |
| Q7 | Cap & overflow | **5 visible + "+M more" inline footer expand button.** Bounded block height (5 rows × 44pt + header + footer ≈ 270pt). Expand button reveals remaining inline (no scroll). Matches T4 14-day cutoff capping pattern. |
| Q8 | Sort order | **`lastActivityAtMs` desc** (most recently active first). Stable on refresh ticks. Self-task affinity boost rejected — Q2=B leaves no state to layer richer ranking on top of; revisit after Phase 5.4 lights up `youNowState`. |
| Q9 | Row composition | **B — Two-line row.** 32pt avatar circle (initials fallback + deterministic color-hash from memberID) | VStack(`displayName` top + "`currentApp · branch?`" bottom, text.tertiary 11pt) | trailing relative-time (text.tertiary 11pt, `RelativeDateTimeFormatter` `<1m → "now"`). Activity Tab `sessionRow` precedent (Phase 4.10.B). NON-tappable per Track-9 §9.1 C-12 carry. |
| Q10 | Atomic commits | **4-commit decomposition + 1 fix-bundle** — C1 substrate · C2 block+HomeView · C3 reader swap+delete · fix-bundle (a11y review IMPORTANTs) · C4 spec landing + SHIPPED. Each commit green build; sequencing avoids breakage. |

---

## 3. Substrate inventory

### 3.1 New substrate APIs (LeafCore additions)

| API / Type | Returns / Shape | Implementation |
|---|---|---|
| `OrgService.activeMemberCount()` | `Int` (≥1; returns 1 when no org / when `readOrg() == nil`) | Public method on existing `OrgService`. Reads `database.readOrg()` → if nil return 1 → else `database.readTeamMembers(orgID:, includeRemoved: false).count`. Throws on DB error (propagates `LeafError.*`). |
| `InsightsSnapshot.activeTeammates: [TeammateSnapshot]` | Defaulted `[]` | Public field. Populated by InsightsReader from existing `TeammatePresenceReader.recentTeammateSnapshots(maxAge:now:)`. |
| `InsightsSnapshot.memberCount: Int` | Defaulted `1` | Public field. Populated by InsightsReader from `OrgService.activeMemberCount()`. |
| `TeamNRowComposer` (new file `LeafCore/Home/TeamNRowComposer.swift`) | Static helpers | Pure functions consumed by the SwiftUI body: `sorted(_:)`, `metaLine(_:)`, `initials(_:)`, `paletteIndex(memberID:paletteCount:)`, `a11yLabel(_:relativeTime:)`, `visibleCap`. |

**Removed surface-level substrate (Q1):**
- `InsightsSnapshot.sameTaskTeammates: [TeammateMatch]` field (was Phase 8.5).
- `InsightsReader.refresh()` `sameTaskTeammates(rule: .hierarchical)` call — replaced by `recentTeammateSnapshots(maxAge: 15 * 60, now:)` call.
- Init param `sameTaskTeammates: sameTaskTeammates` — replaced by `activeTeammates: activeTeammates, memberCount: memberCount`.

**Preserved orphan library code (no consumer after T6, but substrate kept):**
- `DerivedInsights.sameTaskTeammates(rule:)` protocol method.
- `TeammateMatch` value type.
- `SameTaskMatcher` deriver + `SameTaskMatcherTests`.
- `ProdInsights+SameTaskTeammates.swift` moat impl.

### 3.2 Substrate UNCHANGED

- `TeammatePresenceReader` protocol — `recentTeammateSnapshots(maxAge:now:)` already declared; `StubTeammatePresenceReader` already returns `[]`.
- `TeammateSnapshot` value type — 7 fields preserved (Q2=B, no `youNowState` field add).
- `OrgService.createPersonalOrg(displayName:)` + `OrgService.currentOrg()` — untouched.
- `Database.readTeamMembers(orgID:, includeRemoved:)` — existing API consumed by new OrgService accessor.

### 3.3 No new substrate

- **Event kinds:** 0 (registry frozen at 198).
- **SQLCipher migrations:** 0 (30 tables preserved).
- **MCP tools:** 0 (15-tool inventory preserved).
- **ShareEventTypeKey:** 0 delta.
- **UserDefaults keys:** 0.

### 3.4 New SwiftUI views

| File | Path | Final LOC |
|---|---|---|
| `TeamNBlock.swift` | `Leaf/Views/Window/Home/Blocks/` | 169 |

### 3.5 Killed views

| File | Path | Reason |
|---|---|---|
| `WithYouOnThisBlock.swift` | `Leaf/Views/Window/Home/Blocks/` | Superseded by `TeamNBlock` |

### 3.6 Modified views

| File | Change |
|---|---|
| `Leaf/Views/Window/Home/HomeView.swift` | Zone 3 layout: replace single `WithYouOnThisBlock` callsite with `ViewThatFits { HStack { NeedsYouBlock + TeamNBlock } ; VStack { NeedsYouBlock + TeamNBlock } }` gated by `snapshot.memberCount > 1`; if `memberCount == 1` Zone 3 collapses to NEEDS YOU full-width only. 292 → 309 LOC (within master spec §7.2 gate ≤ 310). |

---

## 4. Row composition contract

**TeamNBlock body composition tree:**

```
VStack(spacing: LeafSpace.md)
  header: Text("TEAM · \(activeTeammates.count) · active")
    .leafSectionLabel()
    .foregroundStyle(LeafColor.text.tertiary)
    .accessibilityLabel("Team, \(count) active")    // Stage 6 a11y fix-bundle
    .accessibilityAddTraits(.isHeader)
  LeafCard(padding: .regular) {
    if activeTeammates.isEmpty
      → LeafEmptyState(
          icon: LeafIcons.brand.leaf,
          title: "Team presence sync coming soon.",
          description: nil,
          ctaTitle: nil,
          onCTA: nil
        )
    else
      → VStack(spacing: LeafSpace.sm)
          ForEach(sorted.prefix(visibleCap), id: \.memberID) → row(snapshot)
          if sorted.count > visibleCap (5)
            → expandFooterButton("→ +\(remaining) more")
                @State private var isExpanded: Bool = false  // block scope
                tap → isExpanded.toggle() → reveals remaining inline
  }
```

**Header N semantic (Q6):** `N = activeTeammates.count` (total active
last-seen ≤ 15 min) — NOT visible-after-cap count. Mirrors WithYouOnThis
precedent (overflow footer exists independent of header).

**row(_ snapshot:) — Q9=B two-line, NOT button-wrapped:**

```
HStack(alignment: .center, spacing: LeafSpace.md) {
    avatarCircle(memberID, displayName)
    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
        Text(snapshot.displayName)
            .font(LeafType.title.small)
            .foregroundStyle(LeafColor.text.primary)
            .lineLimit(1)
        if let meta = TeamNRowComposer.metaLine(snapshot) {
            Text(meta)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
    Spacer(minLength: 0)
    Text(relative)    // hoisted once per render — see "relative-time" below
        .font(LeafType.body.small)
        .foregroundStyle(LeafColor.text.tertiary)
}
.accessibilityElement(children: .combine)
.accessibilityLabel(TeamNRowComposer.a11yLabel(snapshot, relativeTime: relative))
// NOT button-wrapped per Track-9 §9.1 C-12 carry (Phase 5.4 owns tap → teammate detail)
```

**relative-time hoisting (Stage 6 a11y fix-bundle):** `let relative =
formatRelative(msAgo: snapshot.lastActivityAtMs)` computed ONCE at the
top of `row(_:)` and reused for both the visible `Text` and the
`.accessibilityLabel`. Guards against the visible `Text` reading
`"1m ago"` while VO reads `"now"` at the 60s bucket boundary (two
independent `Date()` reads in a slow render pass).

**avatarCircle — 5-token palette (passes `just check-tokens` 3-tier gate):**

```swift
private func avatarTint(forMemberID id: String) -> Color {
    let palette: [Color] = [
        LeafColor.accent.primary,
        LeafColor.accent.emphasis,
        LeafColor.status.info,
        LeafColor.status.danger,
        LeafColor.text.secondary,
    ]
    let idx = TeamNRowComposer.paletteIndex(memberID: id, paletteCount: palette.count)
    return palette[idx]
}
```

`Swift.String.hashValue` is randomized across processes — avatar tint
may drift between launches. Documented carry from WithYouOnThis P5;
cosmetic only (avatar `.accessibilityHidden(true)`, no semantic loss).

**relative time — `HomeRelativeTimeFormatter` Phase 8.9 cached formatter
(NOT `RelativeDateTimeFormatter`):**

```swift
private func formatRelative(msAgo ms: Int64) -> String {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    return HomeRelativeTimeFormatter.format(deltaMs: max(0, nowMs - ms), nowMs: nowMs)
}
```

Bucket ladder: `now / Nm ago / Nh ago / yesterday / N days ago / MMM d`.
Cached `DateFormatter` discipline per Track-9 §9.3 C-37 perf carry.

**metaLine composition (graceful nil-skip, `TeamNRowComposer.metaLine`):**

- `currentApp` non-nil + `branch` non-nil → `"\(currentApp) · \(branch)"`
- exactly one non-nil → that value alone
- both nil → returns `nil` → VStack collapses to single line (displayName only)
- empty-string fields treated identically to `nil` (guards against
  producers emitting `""` for unset fields)

**a11yLabel composition (graceful nil-skip,
`TeamNRowComposer.a11yLabel`):**

Example outputs: `"Anton Bochkarev, Xcode, feat/relay-rotation, 2m ago"`
· `"Misha Zubov, Slack, 8m ago"` · `"Someone, now"`.

**Expand footer (when sorted.count > visibleCap=5):**

`@State private var isExpanded: Bool` at BLOCK scope (not row scope).
Button label: `Text(isExpanded ? "Show less" : "→ +\(remaining) more")`.
`.accessibilityLabel`: pluralized `"Show N more teammate(s)"` /
`"Collapse list"`.

---

## 5. HomeView Zone 3 layout

**Current (T5 SHIPPED state, pre-T6):**

```swift
VStack(alignment: .leading, spacing: LeafSpace.xl) {
    ResumeHeroBlock(...)      // Zone 1
    TodayBlock(...)            // Zone 2
    WithYouOnThisBlock(matches: snapshot.sameTaskTeammates)  // → DELETED
    NeedsYouBlock(...)         // Zone 3 (full-width)
    SinceLastActiveBlock(...)  // Zone 5 (T5)
}
```

**Target (T6 SHIPPED):**

```swift
VStack(alignment: .leading, spacing: LeafSpace.xl) {
    ResumeHeroBlock(...)      // Zone 1
    TodayBlock(...)            // Zone 2
    if snapshot.memberCount > 1 {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: LeafSpace.md) {
                NeedsYouBlock(items: snapshot.inboxItems)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                TeamNBlock(teammates: snapshot.activeTeammates)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                NeedsYouBlock(items: snapshot.inboxItems)
                TeamNBlock(teammates: snapshot.activeTeammates)
            }
        }
    } else {
        NeedsYouBlock(items: snapshot.inboxItems)
    }
    SinceLastActiveBlock(...)  // Zone 5
}
```

**Behavior contract:**
- `memberCount == 1` (solo user) → Zone 3 collapses to NEEDS YOU
  full-width; TeamN absent from layout tree entirely.
- `memberCount > 1` + wide window (HStack fits) → 2-col side-by-side.
- `memberCount > 1` + narrow window (HStack doesn't fit) → vertical
  stack, NEEDS YOU above TEAM·N (priority order baked into VStack child
  order).
- `activeTeammates.isEmpty` (team user with no recent activity) →
  TeamNBlock renders empty CTA; layout unchanged.

**HomeView LOC:** 292 → 309 (within ≤ 310 master spec §7.2 gate 6).

---

## 6. InsightsReader.refresh() call delta

**Removed:**

```swift
let sameTaskTeammates = try insights.sameTaskTeammates(rule: .hierarchical)
try Task.checkCancellation()
```

**Added:**

```swift
// Track-10 T6 — broader presence pulse. Reader returns [] today;
// Phase 5.4 wires DBTeammatePresenceReader against presence_history.
// 15-min maxAge matches master spec §3.4.
let teammateReader = TeammatePresenceReaderFactory.make(database: db)
let activeTeammates = try teammateReader
    .recentTeammateSnapshots(maxAge: 15 * 60, now: Date())
try Task.checkCancellation()
// Track-10 T6 — solo-vs-team gate for HomeView Zone-3.
// `OrgService.activeMemberCount()` is a pure DB read (readOrg +
// readTeamMembers) — no keystore / identity dependencies — so we
// inline-construct here rather than thread a new DI param through
// LeafApp (plan §3.1 API surface contract preserved; OrgService stays
// the canonical accessor for org-shape questions).
let orgService = OrgService(database: db)
let memberCount = try orgService.activeMemberCount()
try Task.checkCancellation()
```

**Init param delta:**

```swift
// before: sameTaskTeammates: sameTaskTeammates,
// after:
activeTeammates: activeTeammates,
memberCount: memberCount,
```

**Plan-vs-realized API-surface deviation:** Plan §11.1 INLINE-FIX
declared "OrgService is already constructed in LeafApp" — empirically
false (OrgService lives only inside OrgReader). Implementation
inline-constructs `OrgService(database: db)` in the same `Task.detached`
block. Pure DB read, no keystore / identity deps mattered for
`activeMemberCount`. Preserves plan §3.1 contract (OrgService as the
canonical accessor) without DI plumbing for a one-shot read.

**Net SQL/protocol call count:** 27 (T5 baseline 26 + net +1 from T6
delta: −1 sameTaskTeammates dropped, +2 activeTeammates + memberCount).
Within master spec §7.2 gate-7 "~30-33" range. Plan's literal "24" was
loose estimate.

---

## 7. ADR-010 / sentinel-injection — T6 EXEMPT

Per master spec §6 — `recentTeammateSnapshots` substrate is covered by
existing `TeammatePresenceReader` walkback lineage (Track-8 P5 +
Track-9), and `activeMemberCount` reads org + team_members structured
columns only (no body / preview / text payload). No new sentinel-
injection test ships in T6. Privacy walkback grep across the T6 diff
scope (TeamNBlock + TeamNRowComposer + InsightsReader + InsightsSnapshot
+ OrgService) returns 0 hits for forbidden fields (`absolute_path` ·
`full_comment_body` · `raw_email` · `notes_body` · `email_subject` ·
`note_body` · `file_contents` · `raw_prompt` · `tool_input` ·
`tool_response` · `response_body` · `prompt`).

---

## 8. Verification gates (final state)

Per master spec §7.2:

1. ✓ 5/5 xcodebuild schemes Debug build SUCCESS (LeafCore /
   LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
2. ✓ T6-owned tests 99/99 GREEN (TeamNRowComposerTests 20 +
   InsightsSnapshotTests 63 incl. 4 new + OrgServiceTests 16 incl. 3
   new). Pre-existing flake
   `ProdLinearGraphQLProviderTests/testWarmState_HappyPath_TrackD1`
   carries to follow-up; out of T6 diff scope (verified empty diff on
   `ProdLinearGraphQLProviderTests.swift`).
3. ✓ `just check-tokens` 3-tier clean (BASE / MIGRATION / RETIRED).
4. ✓ Privacy walkback grep — 0 forbidden-field hits in T6 diff scope.
5. ✓ Sentinel-injection — N/A (T6 EXEMPT per §6 / master spec §6).
6. ✓ HomeView.swift LOC 309 ≤ 310.
7. ✓ InsightsReader.refresh() net SQL/protocol call delta +1 (within
   master spec range).
8. ✓ No new SQLCipher migrations — empty diff on
   `Packages/LeafCore/Sources/LeafCore/DB/`.
9. ✓ No new ShareEventTypeKey entries — empty diff on
   `ShareEventTypeRegistry.swift`. Registry frozen at 198.

---

## 9. Dependencies + carry chain

**T6 depends on (already shipped):**
- T3 SHIPPED — `YouNowStateBadge` primitive (NOT consumed in T6 per
  Q2=B, but precedent for Phase 5.4 row badge swap).
- T4 SHIPPED — `NeedsYouBlock` Zone 3 callsite (T6 wraps it in
  ViewThatFits).
- T5 SHIPPED — InsightsReader.refresh() T5 calls preserved; T6 adds 2,
  removes 1 around T5 callsite.
- Track-8 P5 SHIPPED — `TeammatePresenceReader` protocol +
  `StubTeammatePresenceReader` + `TeammateSnapshot` 7-field shape.

**T6 emits to (downstream):**
- **Phase 5.4** (DB-backed `TeammatePresenceReader` +
  `presence_history` consumption + `youNowState` field add to
  `TeammateSnapshot`) — lights up TeamN rows automatically once reader
  stub is replaced. Phase 5.4 also patches TeamNBlock row to add
  `YouNowStateBadge` (swap plain-text time → state badge).
- **Track-9 §9.1 C-12 carry** (TEAM·N row tap → per-teammate detail
  screen) — Phase 5.4 / post-Phase-5.4 carry. T6 ships rows
  NON-tappable.

**T6 emits carries (Stage 6 review NITs deferred to Track-10 T9
polish):**

a11y NITs (sub-agent verdict 0 BLOCKERS · 2 IMPORTANTs fixed in
fix-bundle `cb4b3ce9` · 4 NITs deferred):
- N-1 (footer `→` arrow VO override already correct via
  `accessibilityLabel` — verify during smoke).
- N-2 (LeafEmptyState icon-then-title VO order — design-system
  component, out of T6 scope).
- N-3 (ViewThatFits narrow focus order — verified clean, no action).
- N-4 (paletteIndex randomization — cosmetic, avatar hidden from VO).

Code-review NITs (sub-agent verdict APPROVE-WITH-NITS · 5 NITs
deferred):
- 1 (hoist `TeammatePresenceReaderFactory.make` +
  `OrgService(database:)` out of refresh() hot loop once Phase 5.4
  lights up DBTeammatePresenceReader — currently re-constructed each
  ~5min tick; stub today, may hold prepared statements post-5.4).
- 2 (animation key narrowing — `value: teammates.map(\.memberID)`
  set-identity rather than full snapshot eq to avoid tick-boundary
  re-animation).
- 3 (paletteIndex cross-launch stability via FNV-1a — same carry as
  WithYouOnThis P5).
- 4 (footer `→` arrow → SF Symbol for L10n).
- 5 (`teammate(s)` plural → String Catalog when L10n track lands).

---

## 10. Out of scope

- `YouNowStateBadge` per-teammate row rendering (Phase 5.4 — Q2=B).
- `TeammateSnapshot.youNowState` field add (Phase 5.4).
- DB-backed `TeammatePresenceReader` impl (Phase 5.4).
- Per-teammate detail screen on row tap (Track-9 §9.1 C-12 — Phase 5.4
  / post).
- New `Database.countActiveTeamMembers(orgID:)` SQL method (not needed
  — uses existing `readTeamMembers().count`; performance acceptable for
  ≤50-member teams; add as v1.1 optimization if profiling demands).
- Self-task affinity boost ranking in Q8 sort (revisit after Phase 5.4).
- Adaptive single-line/two-line row composition (Q9 C-option rejected
  for testing burden).
- `LeafAvatarCircle` shared design-system primitive extraction
  (file-local helper + LeafCore pure helpers in T6; extract in T9
  polish if 2+ surfaces share).
- **Orphan substrate cleanup** — `DerivedInsights.sameTaskTeammates(rule:)`
  protocol method + `TeammateMatch` type + `SameTaskMatcher` deriver +
  `SameTaskMatcherTests` + `ProdInsights+SameTaskTeammates.swift` moat
  impl become orphan library code after T6 surface removal. Deferred to
  post-Track-10 cleanup phase (or absorbed into Phase 5.4 if it wants to
  re-introduce same-task ranking via the existing substrate). Tests
  stay green; carrying cost is ~5 files unused.
- Recap/EOD time-of-day reveal (T8).
- YOU'RE ON anchor (T7).
- Track-10 wrap (T9).

---

## 11. Net-LOC tally at impl close

```
git diff feature/track-10-operational-home..feature/GUN-48-track-10-T6-team-n-broader-pulse --stat
 Leaf/Models/InsightsReader.swift                   |  28 ++-
 Leaf/Views/Window/Home/Blocks/TeamNBlock.swift     | 169 ++++++++++++++++++
 Leaf/Views/Window/Home/Blocks/WithYouOnThisBlock.swift | 191 ---------------------
 Leaf/Views/Window/Home/HomeView.swift              |  29 +++-
 Packages/LeafCore/Sources/LeafCore/Home/TeamNRowComposer.swift | 85 +++++++++
 Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift | 42 +++--
 Packages/LeafCore/Sources/LeafCore/Team/OrgService.swift | 10 ++
 Packages/LeafCore/Tests/LeafCoreTests/InsightsSnapshotTests.swift | 41 +++--
 Packages/LeafCore/Tests/LeafCoreTests/OrgServiceTests.swift | 49 ++++++
 Packages/LeafCore/Tests/LeafCoreTests/TeamNRowComposerTests.swift | 176 +++++++++++++++++++

 10 files changed, 587 insertions(+), 233 deletions(-)
```

Net surface delta: +354 LOC (+587 / −233). Net substrate delta: zero
new SQLCipher tables · zero new event_kinds · zero new MCP tools ·
ShareEventTypeKey registry frozen at 198. T6 = pure UI surface +
additive Snapshot/OrgService accessor.

---

## 12. Commit history (final)

```
03f4b05c  feat(GUN-48): InsightsSnapshot.activeTeammates+memberCount + OrgService.activeMemberCount (Track-10 T6)
45feecbd  feat(GUN-48): TeamNBlock + HomeView Zone 3 ViewThatFits split (Track-10 T6)
a0b208c6  feat(GUN-48): InsightsReader swap to recentTeammateSnapshots + drop sameTaskTeammates field + delete WithYouOnThisBlock (Track-10 T6)
cb4b3ce9  fix(GUN-48): review fix-bundle — a11y header VO label + cached row relative time (Track-10 T6)
[C4]      docs(GUN-48): SHIPPED — Track-10 T6 phase spec landing + current-state update
```

Linear UI status flip In Progress → Done lands manually with C4 push.
