# Track-10 T8 — RECAP + EOD standup helper phase spec

**Linear**: GUN-51
**Status**: SHIPPED 2026-05-23. Authored from approved Stages 1-2 brainstorm
(Q1..Q8 closed) + Stage 4 plan `~/.claude/plans/gun-xxx-track-10-t8-linked-candy.md`
+ Stage 4.5 CTO double-pass (6 HIGH inline-fixed of 7 — F-CTO-T8-A downgraded
to LOW after constant verification / 6 MEDIUM disposed / 9 LOW disposed;
0 outstanding CRITICAL). Stages 5-8 landed 2026-05-23. Commit trail on
`feature/GUN-51-track-10-T8-recap-eod`:
- C1 `97491277` — StandupSnapshot + StandupRecap + StandupEod value types
- C2 `432e37e2` — StandupComposer pure helpers + LinearActivityKinds +
  GitHubActivityKinds (+ SinceLastActiveItem.verbMap migration same commit)
- C3 `025f995c` — InsightsSnapshot.standupRecap defaulted-init (14th iteration)
- C4 `eb48f57f` — InsightsReader.refresh() yesterday + today compose
- C5 `7252e90b` — RecapBlock + EodBlock + StandupHeaderRow primitives
- C6 `7de9c991` — HomeContent Zone-5 wiring
- fix `fe92ffca` — Stage 6 review fix-bundle (tomorrowResume doc tightening +
  dead `@Environment(\.calendar)` removal)
- C7 (this commit) — SHIPPED docs landing

Stage 6 dual review: code APPROVE-WITH-NITS (0 BLOCKERS, 2 IMPORTANTs
fix-bundled inline, 6 NITs → Track-10 T9 polish carries) + a11y
APPROVE-WITH-NITS (0 BLOCKERS, 0 IMPORTANTs, 2 NITs → T9). Stage 7: 9/9
§7.2 gates green.

**Branch**: `feature/GUN-51-track-10-T8-recap-eod` (off
`feature/track-10-operational-home` tip `a2fe3784` = T7 SHIPPED after
FF-merge of `feature/GUN-50-track-10-T7-youre-on-anchor`).

**Master spec contract**:
`docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` —
§4 T8 · §3.7 · §3.10 · §5.4 · §6 · §7.2.

**Precedent specs**:
- T5 SINCE YOU WERE LAST ACTIVE (reused substrate API `recentActivityFeed`
  consumed twice per refresh — once per day window):
  `docs/superpowers/specs/2026-05-22-track-10-T5-since-last-active.md`.
- T6 TEAM·N broader pulse (LeafCore pure-helper composer extraction
  precedent · defaulted-init blast-radius pattern):
  `docs/superpowers/specs/2026-05-23-track-10-T6-team-n-broader-pulse.md`.
- T7 YOU'RE ON anchor (`HomeContent.swift` extraction · composer pattern
  · Stage 4.5 CTO discipline · `Equatable+Hashable+Sendable, no Codable`
  precedent F-CTO-A):
  `docs/superpowers/specs/2026-05-23-track-10-T7-youre-on-anchor.md`.

---

## 1. Goal

Light up **Zone-5** of the operational Home — two collapsible standup-helper
blocks at the bottom of `HomeContent`. **RECAP** (morning brief,
auto-expanded 06:00–11:00) summarises yesterday's work for daily standup;
**EOD** (end-of-day, auto-expanded 17:00–23:00) closes the loop with today's
wrap + tomorrow's resume anchor.

T8 is the **second pure-UI surface phase** of Track-10 after T1 Foundation
(T2/T5/T7 added substrate; T3/T4/T6 were UI-only).

**Substrate-purity constants held (Brainstorm Q1=A lock):**
- 0 new event_kinds (registry frozen at **198**)
- 0 new SQLCipher migrations (30 tables preserved · M001-M018 + M024 +
  M026 + M027)
- 0 new MCP tools (15 frozen)
- 0 new `ShareEventTypeKey` entries
- T8 **EXEMPT** from §6 sentinel-injection per master spec §6 line 469 —
  composition of existing Track-3 D1..D3 + Track-1 D3 + Track-10 T5
  protocol APIs already covered by upstream walkback discipline
  (`LEAKED_SENTINEL_T5_RECENT_FEED` covers Linear / GitHub / Slack via
  `recentActivityFeed`).

---

## 2. Brainstorm decisions (closed)

| Q | Decision | Rationale |
|---|---|---|
| Q1 Linear completed-issue keys path | **A — Reuse T5 `recentActivityFeed(since:limit:)`** | `LinearTransitionBreakdown` exposes only aggregate counts (no per-issue ids); T5 substrate exposes `targetRef` (LEAF-NN) + `eventKind` discriminator + `actorIsMe` filter. Walkback discipline already in `LEAKED_SENTINEL_T5_RECENT_FEED`. |
| Q2 Hour-boundary auto-reveal | **A — Initial @State snapshot only** | `@State expanded` resolved once at view init from `Calendar.current.component(.hour, from: now)`. No `TimelineView.periodic` / Timer. User keeps RECAP open at 11:01 = no surprise collapse. |
| Q3 Manual toggle persistence | **A — @State only, resets on rebuild** | Master spec §5.5 line 428 verbatim. No UserDefaults shim under speculative demand. Carry "persistent collapsed state" to v1.1 if user feedback emerges. |
| Q4 Off-hours block visibility | **A — Always-visible chevron headers** | Both `▾ RECAP` / `▾ EOD` headers render even when collapsed 11:00–17:00 / 23:00–06:00. Discoverability via header tap. |
| Q5 Empty-state copy | **A — Separate per block** | RECAP: "Nothing captured yesterday." · EOD: "Nothing captured today yet." Master spec §3.10. |
| Q6 Section header copy | **A — Clean `RECAP` / `EOD` caps labels** | Matches `TODAY` / `NEEDS YOU` / `TEAM·N` / `SINCE` / `YOU'RE ON` convention. |
| Q7 Stale-ask cutoff | **A — 24h hardcoded** | `stalenessCutoffMs = 24 * 60 * 60 * 1000` constant in `StandupComposer`. Configurable later if needed. |
| Q8 Stage 4.5 CTO review | **A — Full pass with findings table** | Adversarial re-read; HIGH inline-fix; MEDIUM/LOW disposition table. |

---

## 3. Surface contract (as shipped)

### 3.1 LeafCore additions

**`StandupSnapshot` value type** —
`Packages/LeafCore/Sources/LeafCore/Insights/StandupSnapshot.swift` (~125 LOC).
Bundled wrapper `{recap: StandupRecap?, eod: StandupEod?}`. Both inner types
intentionally structured (raw counts + identifier arrays + reused snapshots)
rather than pre-formatted strings — view-tier composes display strings via
`StandupComposer.render*`. `Equatable + Hashable + Sendable` only;
**Codable intentionally omitted** per T7 F-CTO-A precedent — nested
`InboxItem` / `Blocker` / `TaskIdentity` / `WhereStoppedSnapshot` are not
Codable; this matched real impl over the plan's aspirational §3.1 claim.

```swift
public struct StandupSnapshot: Equatable, Hashable, Sendable {
    public let recap: StandupRecap?  // nil → RECAP empty-state
    public let eod: StandupEod?      // nil → EOD empty-state
    public init(recap: StandupRecap?, eod: StandupEod?)
}

public struct StandupRecap: Equatable, Hashable, Sendable {
    public let yesterdayCommitsCount: Int
    public let yesterdayClosedLinearKeys: [String]   // cap 5
    public let yesterdayReviewedPRsCount: Int
    public let todayContinuing: TaskIdentity?
    public let waitingItems: [InboxItem]              // age > 24h, cap 3
    public let openBlockers: [Blocker]                // cap 3
    public var isEmpty: Bool { /* all signals zero */ }
}

public struct StandupEod: Equatable, Hashable, Sendable {
    public let todayCommitsCount: Int
    public let todayClosedLinearKeys: [String]        // cap 5
    public let todayReviewedPRsCount: Int
    public let tomorrowResume: WhereStoppedSnapshot?  // excerpt-only read
    public let carryWaitingItems: [InboxItem]         // cap 3
    public let carryOpenBlockers: [Blocker]           // cap 3
    public var isEmpty: Bool
    public var hasCleanBreak: Bool { carry arrays empty }
}
```

**`StandupComposer` pure helpers** —
`Packages/LeafCore/Sources/LeafCore/Home/StandupComposer.swift` (~180 LOC).
Mirrors `TeamNRowComposer` / `YoureOnRowComposer` — static, pure,
deterministic.

Constants (tunable per test):
- `stalenessCutoffMs = 24 * 60 * 60 * 1000`
- `issueKeysCollectionCap = 5` / `issueKeysRenderCap = 3` (F-CTO-T8-N split:
  composer collects 5 for future surfaces; view renders 3 + `+N more`)
- `waitingCap = 3` / `blockersCap = 3`

Top-level `compose(...)` returns `StandupSnapshot` with `nil` children when
either window has no meaningful content (view-tier empty-state routing).

`extractCompletedLinearKeys(_:)` — F-CTO-T8-B regression locked: sort by
`ts desc` **BEFORE** dedupe so re-closed issues keep their most-recent
occurrence position. Filters `source == .linear && actorIsMe &&
eventKind == LinearActivityKinds.statusTransitionCompletedKind && targetRef
non-nil`. Cap at `issueKeysCollectionCap`.

`countReviewedPRs(_:)` — exact-match
`GitHubActivityKinds.prReviewAuthoredKind` (F-CTO-T8-S verified by grep
against `ProdInsights+RecentActivityFeed.swift`). Excludes
`gh_pr_review_requested` (review-requested-OF-me is not "I reviewed").

`staleWaitingItems(_:now:)` — `> stalenessCutoffMs` (boundary inclusive of
24h0m1ms, exclusive of <24h). Sort by `severity.sortRank` asc → oldest
first. Cap at `waitingCap`.

`renderLinearKeysClause(_:)` — empty → `nil`; otherwise `"closed X, Y, Z
+N more"` with overflow once `issueKeysRenderCap` is hit.

`formatItemAge(_:now:)` — pure integer arithmetic, no DateFormatter
(allocation-free at 1000× call sites). `<60s` → `"now"`; `<60m` → `"Nm"`;
`<24h` → `"Nh"`; `>=24h` → `"Nd"`. POSIX-equivalent; localization deferred
to carry C-T8-5.

`isRecapExpanded(atHour:)` / `isEodExpanded(atHour:)` — `(6..<11)` / `(17..<23)`
boundary; extracted to composer so view-tier `RecapBlock` / `EodBlock`
`@State expanded` seeds are XCTest-locked without ViewInspector.

**`LinearActivityKinds` + `GitHubActivityKinds` namespaces** —
`Packages/LeafCore/Sources/LeafCore/Insights/{Linear,GitHub}ActivityKinds.swift`
(~20 LOC combined). Single source of truth for event_kind discriminators
emitted by `ProdInsights+RecentActivityFeed`. **SinceLastActiveItem.verbMap
migrated same commit** to read from the namespace constants — no string
duplication can drift apart.

**`InsightsSnapshot.standupRecap: StandupSnapshot?`** —
14th defaulted-init iteration. Tail-positioned after `currentSession`. Two
new XCTest cases (`testSnapshotDefaultsStandupRecapToNil`,
`testSnapshotCarriesStandupRecap`); 65 existing tests stay green without
modification — confirming the defaulted-init blast-radius is zero.

### 3.2 `InsightsReader.refresh()` composition

Inserted after T7 `currentSession()` write. **SQL call count delta: +4**
(baseline 23 → 27, within master spec §7.2 gate 7 envelope):
- `recentActivityFeed(since: yesterdayMs, limit: 100)` — yesterday window
- `recentActivityFeed(since: todayMs, limit: 100)` — today window
- `todayMetrics(now: yesterdayStart)` — yesterday's commits-per-day
- `openBlockers()` — currently-open blockers

F-CTO-T8-C documented inline: `dateInterval(of: .day, for:)` returns 23h on
spring-forward, 25h on fall-back; epoch-ms math correct because
`recentActivityFeed` works on `Int64` ms. F-CTO-T8-L fallback:
`Calendar.date(byAdding:value:to:)` returns Optional → fallback
`now.addingTimeInterval(-86_400)` so `yesterdayStart` never collapses to
`now`.

### 3.3 SwiftUI view-tier

**`StandupHeaderRow.swift`** — shared chevron header for both blocks.
Real `Button` with `[.isButton, .isHeader]` traits, `accessibilityValue` =
expanded/collapsed, `accessibilityHint` = double-tap action, `minHeight =
44pt` per HIG. Chevron `.accessibilityHidden(true)` so VoiceOver doesn't
read "chevron down" alongside the synthesized state.

**`RecapBlock.swift`** — `@State expanded` seeded from
`StandupComposer.isRecapExpanded(atHour:)` at view init. Empty-state
("Nothing captured yesterday.") takes precedence over `hasCleanBreak`
(F-CTO-T8-I). Yesterday summary composes inline with pluralization
(1 commit / 3 commits, 1 PR / 2 PRs). `Today: continuing GUN-X` only
rendered when `taskIdentity.linearID` present.

**`EodBlock.swift`** — same auto-reveal pattern, `(17..<23)` boundary.
`Clean break: nothing critical hanging.` line gated by `hasCleanBreak &&
!carryHasContent` so an empty-day fresh DB doesn't render the line
spuriously. `Tomorrow: resume <excerpt>` reads excerpt-only from
`WhereStoppedSnapshot` (narrow surface — richer reads deferred to carry
C-T8-7 post Stage 6 IMPORTANT 1 fix-bundle).

### 3.4 HomeContent Zone-5 wiring

`HomeContent.swift` 142 → 151 LOC (+9 LOC, well under 200 budget; HomeView
205 LOC unchanged, well under 310 master spec §7.2 gate 6). File header
doc comment updated to enumerate 5 Zone composition:

```
//    1. RESUME HERO                              (T2)
//    2. TODAY (with inline YOU·NOW state badge)  (T3)
//    3. NEEDS YOU ‖ TEAM·N  (ViewThatFits 2-col) (T4, T6)
//    4. SINCE ‖ YOU'RE ON   (ViewThatFits 2-col) (T5, T7)
//    5. RECAP + EOD standup helpers              (T8)
```

---

## 4. Verification (§7.2 — 9/9 gates green)

1. **5/5 xcodebuild schemes** — Debug build SUCCEEDED on LeafCore /
   LeafCorePrivate / Leaf / LeafAgent / LeafMCP.
2. **SPM test suite** — 1996 XCTest + 45 Swift Testing = **0 failures**
   (60 new tests added: 17 StandupSnapshot + 24 StandupComposer + 2
   InsightsSnapshot defaulted-init; 17 SinceLastActiveItem regression
   tests preserved through `LinearActivityKinds` migration).
3. **`just check-tokens`** — 3-tier clean (BASE + MIGRATION + RETIRED).
4. **Privacy walkback** — 0 hits across 7 new T8 files for
   `absolute_path|full_comment_body|raw_email|notes_body|email_subject|
    note_body|file_contents|raw_prompt|tool_input|tool_response|
    response_body|prompt`.
5. **Sentinel-injection** — N/A (T8 EXEMPT per master spec §6 + Q1=A
   reuses T5's already-walkbacked `recentActivityFeed`).
6. **HomeView.swift LOC** — 205 (≤ 310). Pass.
7. **HomeContent.swift LOC** — 151 (≤ 200, target ~150). Pass.
8. **SQL call count** — 23 → 27 (+4). Within master spec §7.2 envelope.
9. **Substrate-purity** — `git diff` empty for
   `Packages/LeafCore/Sources/LeafCore/{DB,Share,MCP}/`. Registry frozen at
   198 · 30 tables · 15 MCP tools.

**Manual smoke (19h launch):**
- Zone-5 RECAP collapsed by default at 19h (out of `[6, 11)`); chevron
  header always-visible.
- Zone-5 EOD expanded by default at 19h (in `[17, 23)`); body shows
  "Today: closed GUN-50, GUN-49, GUN-40 +2 more" + "Clean break: nothing
  critical hanging."
- Manual chevron tap on RECAP expands body: "Yesterday: 1 commit · closed
  GUN-50, GUN-49, GUN-40 +2 more" + "Today: continuing GUN-51".
- All composer caps verified live: 5 keys collected, 3 rendered, `+2
  more` overflow, `1 commit` pluralization correct.
- Empty-state path covered by fresh-DB regression (composer returns nil
  children → blocks render "Nothing captured yesterday." /
  "Nothing captured today yet." copy).

---

## 5. Stage 4.5 CTO findings — disposition table

| # | Sev | Disposition |
|---|---|---|
| F-CTO-T8-A | LOW (was HIGH) | DOWNGRADED — discriminator constants verified against public `SinceLastActiveItem.verbMap`; hoisted to `LinearActivityKinds` namespace + SinceLastActiveItem migrated same commit. |
| F-CTO-T8-B | HIGH | INLINE FIX — `StandupComposer.extractCompletedLinearKeys` sorts by `ts desc` BEFORE dedupe (`StandupComposer.swift:110`). `testExtractCompletedLinearKeys_dedupePreservesMostRecent` locks the determinism contract. |
| F-CTO-T8-C | HIGH | INLINE FIX — DST behavior documented at `InsightsReader.swift:262-268`. |
| F-CTO-T8-L | LOW | INLINE FIX — Optional fallback `addingTimeInterval(-86_400)` at `InsightsReader.swift:271-272`. |
| F-CTO-T8-N | HIGH | INLINE FIX — `issueKeysCollectionCap=5` + `issueKeysRenderCap=3` split with `+N more` overflow. `renderLinearKeysClause_overflowSuffix` test locks the boundary. |
| F-CTO-T8-O | HIGH | INLINE FIX — `StandupHeaderRow.swift` final name locked. |
| F-CTO-T8-P | HIGH | VERIFIED — `Blocker.id: Int64` + `excerpt: String` matched against `LeafCore/Home/WorkState/Blocker.swift`. |
| F-CTO-T8-S | LOW | INLINE FIX — `GitHubActivityKinds.prReviewAuthoredKind` exact-match constant; grep against `ProdInsights+RecentActivityFeed` confirms discriminator. |
| F-CTO-T8-D, E, F, G, K, M, Q, T, U | MEDIUM/LOW | ACCEPT with rationale per plan §Stage 4.5. F-CTO-T8-E narrow-surface excerpt-only read promoted to ship after Stage 6 IMPORTANT 1 doc-tightening fix-bundle. |
| F-CTO-T8-H | LOW | INLINE FIX — `<60s → "now"` matches T5 precedent. |
| F-CTO-T8-I | LOW | INLINE FIX — empty-state path takes precedence over `hasCleanBreak` (`EodBlock.swift:36-44`). |
| F-CTO-T8-J | LOW | INLINE FIX — explicit `06 / 10 / 11 / 16 / 17 / 22 / 23` boundary tests in `StandupComposerTests`. |

---

## 6. Carries → Track-10 T9 polish

| # | Source | Description |
|---|---|---|
| C-T8-1 | Brainstorm | "Today: D blockers resolved" line — needs `recentlyResolvedBlockers(period:)` substrate (out of T8 envelope) |
| C-T8-2 | F-CTO-T8-D | RECAP "Today: continuing GUN-X" / Zone-4 YOU'RE ON duplication — accept if user feedback shows confusion |
| C-T8-3 | Brainstorm Q3 | Persistent collapsed state (UserDefaults) — defer until 2+ user requests |
| C-T8-4 | Master spec | `get_standup_summary` MCP tool (master spec §5.6) — AI client request |
| C-T8-5 | F-CTO-T8 | `formatItemAge` localization (currently POSIX) |
| C-T8-6 | F-CTO-T8-U | First-launch onboarding hint inside empty Standup blocks |
| C-T8-7 | Stage 6 IMPORTANT 1 | Richer EOD `tomorrowResume` read (anchorBundleID / anchorFilePath / recentLastCommit?.message) — narrow excerpt-only ships today |
| Stage 6 NITs | Code reviewer | Single `let now = Date()` per body · `compose(...)` arity → Inputs struct · `recentActivityFeed` limit constant · symmetric DST doc · VO label lowercasing · `compose(...)` 9th-arg threshold |
| Stage 6 a11y NITs | A11y reviewer | Reduced-motion fallback for chevron `rotationEffect` · `a11yElement(children: .combine)` on Recap/Eod body VStacks |
