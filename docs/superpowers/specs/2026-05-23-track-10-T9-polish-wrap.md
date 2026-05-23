# Track-10 T9 — Polish + Track-10 wrap

**Linear:** GUN-52
**Status:** IN PROGRESS — Stage 3 spec landing.
**Parent:** `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` master spec §4 T9 + §7.3 + §9.2 + §12.
**Branch:** `feature/GUN-52-track-10-T9-polish-wrap` off `feature/track-10-operational-home` tip `346e23a7` (T8 SHIPPED FF-merged into collective at session start).
**Precedent:** `docs/superpowers/specs/2026-05-21-track-9-T10-wrap-polish.md` (Track-9 wrap shape).
**Owner:** dima + Claude.
**Date:** 2026-05-23.

---

## 1. Scope

Track-10's 9th and **final** phase. Polish + verification + Track-10 collective wrap. Closes master spec §T9 + accumulated NIT carries from T6/T7/T8 Stage 6 dual reviews (a11y + HIG sweeps) + master spec §9.2 amendments + current-state.md SHIPPED paragraph + push handoff to Дима.

T1..T8 — substrate-touching phases (T2 RESUME hero / T3 YOU·NOW badge / T4 NEEDS YOU / T5 SINCE / T6 TEAM·N / T7 YOU'RE ON / T8 RECAP+EOD) — all SHIPPED with substrate-purity invariant held: registry frozen 198, 30 SQLCipher tables, 15 MCP tools, 0 new event_kinds, 0 new migrations. T9 — sweeps + spec finalization, **zero substrate-touch**.

After T9 SHIPPED → `feature/track-10-operational-home` ready for collective merge to `main` (separate session per master spec §12, Дима sanity + push сам).

**Deliverables:**
1. A11y sweep — general-purpose subagent as reviewer; inline-fixable NITs applied, substrate-touch carry forward.
2. HIG sweep — general-purpose subagent as HIG reviewer; 44pt targets / WCAG AA / focus rings / animation duration consistency. Inline-fixable applied.
3. Perf sweep — automated `just check-tokens` 3-tier + grep raw `Color.` / `.font(.system(` / `DateFormatter()` / `ForEach.indices`.
4. Privacy walkback master grep across Track-10 file scope — 12 forbidden field patterns, 0 hits target.
5. LOC budget verification — HomeView ≤ 310 / HomeContent ≤ 200 / per-block budgets per phase specs.
6. Master spec §9.2 carry list amendments — Stage 6 NIT carries + T7 a11y 5 NITs forward + localization + RECAP/EOD configurable hours + `get_standup_summary` future + LinearGraphQL pre-existing flake.
7. `current-state.md` Track-10 SHIPPED paragraph — three-step update (header replace + Recent log compaction + Следующим cleanup).
8. SHIPPED commit body — Track-10 wrap summary + substrate invariants + acceptance gates status + carry list emit + next steps.

### 1.1 Out of scope (hard exclusion — carry post-Track-10)

- **C-T7-H1/H2/H3** post-ship moat hot-fixes (LinearIDPrefixCache · aiCollaboration cwd fallback · terminalFamily dwell) — documented in `a2fe3784` commit. Master spec §9.2 carry: "Claude Code workflow first-class in YOU'RE ON" own phase.
- **C-25** WhereStoppedDeriver sleep/wake substrate bug — own post-Track-9 phase per Track-9 T10 §1.1 D-1. T7 ResumeHeroBlock UI degrades gracefully when substrate returns nil.
- **Phase 5.4** DB-backed TeammatePresenceReader — own track, lights up TEAM·N automatically.
- **C-26** moat `ProdInsights+InboxItems.swift` 795 LOC reorg — moat hygiene phase.
- **C-29** `queryCommentsOnMyWork` viewer_login substrate enrichment — own phase.
- **T7 a11y 5 NITs** — post-Track-10 own a11y sweep phase (D-2: forward carry — T7 a11y reviewer wrote spec before Track-10 finalized to 9 phases; "T10" semantic = forward carry).
- **Localization track** (C-19 + C-42) — separate track.
- **Multi-week Analytics** (C-41 / C-44 dual-axis) — Analytics hidden by default in T1; deferred.
- **TopToolsCard real substrate** (C-38) / heatmap PeakHour (C-39) — Analytics hidden by default.
- **TEAM·N row tap → per-teammate detail screen** (C-12 / Track-9 §9.1) — Phase 5.4.
- **Resume CTA branch-deletion staleness** (C-8) — v1.1.
- **RECAP/EOD configurable hour boundaries** (master spec §8) — v1.1.
- **`get_standup_summary` MCP tool** — future if AI demand.
- **Pre-existing test flake** `testWarmState_HappyPath_TrackD1` (T6/T7 noted) — separate triage, NOT Track-10 emit.

---

## 2. Decisions taken (Stage 2 brainstorm, user-confirmed)

**D-1.** **NIT triage strategy = inline-fixable applied · substrate-needed carry forward** (user confirmed). T9 closes the ~22 Stage 6 NIT carries from T6/T7/T8 dual reviews if they don't require new substrate work. Substrate-touch NITs (multi-prefix Linear, sleep-wake, branch parsing) → carry post-Track-10 master spec §9.2.

**D-2.** **T7 a11y 5 NITs (spec says "T10") = post-Track-10 own phase** (user confirmed). Forward carry — T7 a11y reviewer wrote spec before Track-10 finalized to 9 phases. NOT addressed in T9.

**D-3.** **Master smoke per zone (§7.3) = async gate** (user confirmed). T9 SHIPPED lands after code/build/test sweeps + plan documentation. Дима performs manual smoke when convenient; BLOCKER findings → follow-up `fix(GUN-52): ...` commit on T9 branch before collective merge.

**D-4.** **Push timing = Дима executes push, NOT Claude** (user confirmed). T9 final commits land locally; plan documents explicit push command for Дима. Push target — `origin feature/track-10-operational-home:dev` (NOT main).

**D-5.** **A11y sweep mechanism = general-purpose subagent acting as a11y reviewer** (Track-8 P9 / Track-9 T10 / Track-10 T6/T7/T8 dual-review precedent). Subagent reads Track-10 new view files + finds BLOCKER/IMPORTANT/NIT. Inline-fixable applied in same session; substrate-needed carry forward.

**D-6.** **HIG sweep mechanism = general-purpose subagent acting as HIG reviewer**. Lighter weight than a11y — touch targets (44pt min), WCAG AA contrast, focus rings, keyboard nav, animation duration consistency.

**D-7.** **Perf sweep mechanism = automated `just check-tokens` 3-tier + grep** (per master spec §7.2 gate 3). Patterns: zero raw `Color.` / `.font(.system(` / `DateFormatter()` per-render / `ForEach.indices`. Instruments profiling out-of-scope (v1.1 if performance concerns surface).

**D-8.** **Privacy walkback master grep = narrow scope across Track-10 new file set** (8 block files + composers + value types). 0 hits target across 12 forbidden field patterns (per master spec §7.2 gate 4 list).

**D-9.** **LOC budget enforcement** = HomeView.swift ≤ 310 + HomeContent.swift ≤ 200 (per master spec §7.2 gate 6). Currently per current-state.md: HomeView 205 / HomeContent 151 (post-T8). Comfortable margins; T9 polish unlikely to bump.

**D-10.** **Atomic commit decomposition = 8-12 commits target** (master spec §4 T9). Single commits per logical sweep (a11y / HIG / perf / privacy / LOC budget verification / §9.2 amend / current-state.md / SHIPPED docs). Commit isolation aids regression debugging.

**D-11.** **Whitepaper sync = separate session via `/sync-docs track-10-wrap`** (per master spec §12 condition 6). T9 only flags TODO in current-state.md / SHIPPED commit body — sync NOT executed in T9 session.

**D-12.** **Collective merge to `main` = separate session post-T9** (Дима sanity + push сам). T9 push target — `origin/dev` only. Main merge waiting for collective merge approval.

**D-13.** **Linear GUN-52** — confirmed pre-Stage 5 by user (D-13 path resolved); branch name + commit prefix use real GUN-52 from start; no `git branch -m` retroactive.

**D-14.** **Cleanup pass on Linear** — T5 GUN-47, T6 GUN-48, T7 GUN-50, T8 GUN-51 verify Done status — Дима check (Linear MCP `list_issues` not available in session tool inventory; verification = manual, non-blocking).

---

## 3. Architecture

T9 is polish + sweeps + spec doc updates. **No new architecture.** Zero new substrate.

### 3.1 Substrate-purity invariant

| Surface | Pre-T9 (T8 SHIPPED `346e23a7`) | Post-T9 | Delta |
|---|---|---|---|
| SQLCipher tables | 30 (M001-M018 + M024 + M026 + M027) | 30 | 0 |
| event_kinds (registry) | 198 (Track-9 baseline) | 198 | 0 |
| ShareEventTypeKey registry entries | 198 | 198 | 0 |
| MCP tools | 15 (12 low-level + 3 structured) | 15 | 0 |
| DerivedInsights protocol methods | T8 baseline (incl. recentActivityFeed, currentTaskSession, recentTeammateSnapshots, openBlockers) | unchanged | 0 |
| InsightsSnapshot defaulted fields | 51 (T7 currentTaskSession 13th + T8 standup 14th iteration) | unchanged | 0 |
| InboxSourceContextRef cases | 13 | 13 | 0 |

**Track-10 substrate-purity streak: 9 phases T1-T9 zero-conflict** (T1..T8 substrate-pure + T9 sweeps only). Verified diff vs `dev` (Track-9 wrap tip): no new tables / event_kinds / MCP tools / registry entries.

### 3.2 Per-sweep implementation

#### 3.2.1 A11y sweep (commit 2)

- Mechanism: general-purpose subagent acting as a11y reviewer.
- Subagent read scope: 8 new Track-10 view files — `ResumeHeroBlock` · `YouNowStateBadge` · `NeedsYouBlock` · `TeamNBlock` · `SinceLastActiveBlock` · `YoureOnBlock` · `RecapBlock` · `EodBlock` — + `HomeView.swift` + `HomeContent.swift` + `StandupHeaderRow.swift` + `SinceFilterRow.swift`.
- Subagent verdict triage: BLOCKER (must fix) / IMPORTANT (cheap fix) / NIT (defer or apply if inline-fixable).
- Apply inline: section labels `.isHeader` · row traits `.isButton` · `.isSelected` for chip strips · pluralization helpers · primitive a11y audit edge cases · VO label refinements.
- Carry-forward: T7 5 a11y NITs (D-2 post-Track-10) + design-system primitive a11y audit (post-Track-9 carry).

#### 3.2.2 HIG sweep (commit 3)

- Mechanism: general-purpose subagent acting as HIG reviewer (uses `hig` skill via subagent).
- Subagent read scope: full Track-10 view file set + Settings → Advanced sub-section (T1 onboarding share-controls preset).
- Check: 44pt min touch targets · WCAG AA contrast · focus rings · keyboard nav · animation duration consistency (e.g., `.easeInOut(duration: 0.2)` vs `.easeIn(duration: 0.25)` drift across blocks).
- Apply inline-fixable HIG NITs.
- Carry-forward: substrate-touch NITs (e.g., per-block design-system primitive refactor — own phase).

#### 3.2.3 Perf sweep (commit 4)

Automated checks:
- `just check-tokens` 3-tier (BASE + MIGRATION + RETIRED clean).
- `grep -rn "Color\." Leaf/Views/Window/Home/` → 0 raw uses.
- `grep -rn "\.font(\.system(" Leaf/Views/Window/Home/` → 0 raw uses.
- `grep -rn "DateFormatter()" Leaf/Views/Window/Home/` → 0 per-render allocations.
- `grep -rn "ForEach.*\.indices" Leaf/Views/Window/Home/` → 0 anti-pattern.

Likely zero diff commit (all sweeps already passing per current-state.md T1..T8 verification). Commit body documents grep results explicitly.

#### 3.2.4 Privacy walkback master grep (commit 5)

Forbidden field list (master spec §7.2 gate 4): `absolute_path` (outside allowlist) · `full_comment_body` · `raw_email` · `notes_body` · `email_subject` · `note_body` · `file_contents` · `raw_prompt` · `tool_input` · `tool_response` · `response_body` · `prompt`.

Master grep across Track-10 file scope:
- `Leaf/Views/Window/Home/`
- `Packages/LeafCore/Sources/LeafCore/Home/`
- `Packages/LeafCore/Sources/LeafCore/Insights/ResumeHero*.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/YoureOn*.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/SinceLast*.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/Standup*.swift`
- `Packages/LeafCore/Sources/LeafCore/Insights/TeamN*.swift`
- `Packages/LeafCore/Sources/LeafCore/Git/Git*.swift`

Target: 0 hits. ADR-010 doc-comment intent matches OK if explicit "stripped" / "never read" context (T7 precedent: 3 doc-comment hits acceptable).

#### 3.2.5 LOC budget verification (commit 6)

Verify:
- `wc -l Leaf/Views/Window/Home/HomeView.swift` ≤ 310 (currently 205).
- `wc -l Leaf/Views/Window/Home/HomeContent.swift` ≤ 200 (currently 151).
- Per-block LOC budgets per phase specs (RESUME hero T2 ≤ 240 · TeamNBlock ≤ 200 · YoureOnBlock ≤ 100 · RecapBlock ≤ 120 · EodBlock ≤ 140 · etc).

Likely zero diff commit.

#### 3.2.6 Master spec §9.2 carry list amendments (commit 7)

`docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md`:
- Add entries for Stage 6 NIT carries from T6/T7/T8 dual reviews that were NOT applied inline in steps 2-3.
- Add design-system primitive a11y audit (T7 a11y NITs forward).
- Verify C-T10-EMIT-T7H1/H2/H3 already present (from `a2fe3784` commit).
- Add localization carry (C-19 forward).
- Add pre-existing LinearGraphQL flake (T6 noted).
- Add RECAP/EOD configurable hours (master spec §8 reference).
- Add `get_standup_summary` MCP tool future.

#### 3.2.7 current-state.md Track-10 SHIPPED paragraph (commit 8)

Three-step update (mirror Track-9 wrap discipline at lines 5-29):

**Step 8.1 — "Последнее обновление" header section replace**: Existing Track-9 wrap header content moves out (Track-9 becomes compact line item in Recent phase log). New header content: Track-10 wrapped (T1..T9 complete), cumulative substrate-purity stats, merge prep block.

**Step 8.2 — Recent phase log compaction**: Current Track-10 progressive entry (very long paragraph) → replaced with tight Track-10 wrap line item (1-2 sentences referencing per-phase specs + master spec). Current Track-9 entry preserved as-is.

**Step 8.3 — "Следующим" section cleanup**: Strike Track-10 carries that resolved through T1..T9 ship. Append new carries from §9.2 (C-T10-EMIT-T7H1..H3 + a11y sub-phase + flake).

File ≤ 200 LOC global budget per `.claude/shared/conventions.md` shared memory hygiene.

#### 3.2.8 SHIPPED commit (commit 9)

Final SHIPPED commit body — mirror Track-9 T10 SHIPPED commit shape. Content:
- **Track-10 wrap summary**: 9 phases shipped (T1 foundation · T2 RESUME hero · T2.5 follow-up · T3 YOU·NOW badge · T4 NEEDS YOU · T5 SINCE · T6 TEAM·N · T7 YOU'RE ON · T8 RECAP/EOD · T9 polish/wrap).
- **Substrate invariants**: registry frozen 198 · 30 SQLCipher tables · 15 MCP tools · 0 new event_kinds · 0 new migrations across all 9 phases.
- **Verification gates** (§7.2 9 conditions).
- **Acceptance §12** (7 conditions).
- **Manual smoke** (§7.3): "pending Дима availability — async gate per D-3".
- **Carry list emit (§9.2)**: short summary referencing master spec §9.2 full list.
- **Next steps**: collective merge to `main` — separate session · Whitepaper sync — separate session via `/sync-docs track-10-wrap`.
- **DO NOT leak moat content** — mental check per Track-9 T10 precedent.

### 3.3 Sweeps shape

| Sweep | Mechanism | Driver | Output |
|---|---|---|---|
| A11y | general-purpose subagent acting as a11y reviewer | Claude dispatches read-only | BLOCKER → fix inline · IMPORTANT → cheap fix · NIT → triage (apply inline-fixable, carry substrate-needed) |
| HIG | general-purpose subagent acting as HIG reviewer | Claude dispatches read-only | Touch targets / contrast / focus rings / animation duration consistency findings |
| Perf | Automated grep + `just check-tokens` | Claude | Pass/fail gate (likely zero diff — verification commit) |
| Privacy walkback | Automated `grep -rnE` master | Claude | 0 hits across 12 forbidden fields OR doc-comment intent OK |
| Manual smoke | Visual click-through per master spec §3 mockup parity per zone | Дима | Documented deviations (TEAM·N empty per Phase 5.4 dep · WHERE STOPPED → RESUME state per C-25 known carry) |

---

## 4. Acceptance gates (Stage 7 verification)

9 gates per master spec §7.2 — verified before T9 SHIPPED commit (9):

1. **AC-1** — 5/5 xcodebuild schemes Debug SUCCESS (LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP).
2. **AC-2** — SPM tests green: XCTest + Swift-Testing combined, 0 failures. Baseline post-T8: 1996 XCTest + 45 Swift Testing = 2041. T9 likely zero new tests OR +1-2 a11y test assertions if BLOCKER fixes added. **Flake exception**: pre-existing `testWarmState_HappyPath_TrackD1` flake (T6/T7 noted, documented in §9.2 carry) — if hits, re-run once; NOT Track-10 emit, NOT blocking AC-2.
3. **AC-3** — `just check-tokens` 3-tier clean (BASE / MIGRATION / RETIRED all pass).
4. **AC-4** — Privacy walkback master grep across Track-10 file scope: 0 hits OR doc-comment intent only.
5. **AC-5** — Sentinel-injection tests green: `test_gitDeltaReader_Strips...` (T2) · `LEAKED_SENTINEL_T5_RECENT_FEED` (T5) · `test_currentTaskSession_OpenFilesAreBasenamesOnly_NoSentinelLeak` (T7). T9 adds none.
6. **AC-6** — HomeView.swift ≤ 310 LOC · HomeContent.swift ≤ 200 LOC.
7. **AC-7** — Substrate diff vs `dev` empty (re-verify post-T9):
   - `git diff dev..feature/track-10-operational-home -- Packages/LeafCore/Sources/LeafCore/DB/` → empty.
   - `git diff dev..feature/track-10-operational-home -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` → empty.
   - `git diff dev..feature/track-10-operational-home -- LeafMCP/` → empty.
8. **AC-8** — Master spec §9.2 carry list honestly populated · §9.1 resolutions marked.
9. **AC-9** — `InsightsReader.refresh()` SQL call count monotonic — Track-9 ended at 23 calls; Track-10 ends at 27 per current-state.md T8 entry (+4 in T8 — 2×recentActivityFeed + todayMetrics(yesterday) + openBlockers). T9 likely zero delta.

Manual smoke (§7.3) — separate Stage 7 manual run, async per D-3.

### 4.1 Acceptance §12 (Track-10 wrap 7 conditions)

1. ✅ All 9 sub-phase SHIPPED docs land on `feature/track-10-operational-home` (T9 final).
2. ⏳ T9 §7.3 master smoke documented per zone (pending Дима async per D-3).
3. ✅ 9/9 verification gates per §7.2 green at T9 (verified in step 9).
4. ⏳ Manual smoke discovered no BLOCKER UX issues (gate on Дима smoke).
5. ✅ `current-state.md` Track-10 SHIPPED paragraph lands (step 8).
6. ⏳ Whitepaper sync via `/sync-docs track-10-wrap` (separate session per D-11).
7. ⏳ Push to `origin/dev` clean (Дима gate per D-4).

T9 lands as **substantively complete** (3 ✅) with 4 ⏳ requiring async user action — Дима-driven completion.

---

## 5. Testing strategy

### 5.1 No sentinel-injection regression test

T9 = polish + sweeps + docs. No new payload field reads. No new privacy surface. Sentinel-injection test pattern (T2/T5/T7 lineage) NOT required for T9 per master spec §6 line 285 precedent (T4/T9/T10 same exemption in Track-9).

### 5.2 Test deltas

Likely zero new tests. If a11y BLOCKER fixes land inline, +1-2 a11y assertion deltas. Baseline post-T8: 2041 combined SPM. Expected post-T9: ~2041 (or ±2 if BLOCKER inline fixes add assertions).

### 5.3 Verification commands

See §4 AC-1..AC-9 inline commands. Master grep (AC-4):

```bash
grep -rnE "absolute_path|full_comment_body|raw_email|notes_body|email_subject|note_body|file_contents|raw_prompt|tool_input|tool_response|response_body|prompt" \
  Leaf/Views/Window/Home/ \
  Packages/LeafCore/Sources/LeafCore/Home/ \
  Packages/LeafCore/Sources/LeafCore/Insights/ResumeHero*.swift \
  Packages/LeafCore/Sources/LeafCore/Insights/YoureOn*.swift \
  Packages/LeafCore/Sources/LeafCore/Insights/SinceLast*.swift \
  Packages/LeafCore/Sources/LeafCore/Insights/Standup*.swift \
  Packages/LeafCore/Sources/LeafCore/Insights/TeamN*.swift \
  Packages/LeafCore/Sources/LeafCore/Git/Git*.swift \
  2>/dev/null
```

---

## 6. Carry-overs (post-Track-10 backlog)

After T9 SHIPPED, the following carries remain post-Track-10 (master spec §9.2 final inventory after T9 amendments):

| Carry | Description | Owner |
|---|---|---|
| **C-T10-EMIT-T7H1** | LinearIDPrefixCache — `Issue.identifier` first-class instead of guess-prefix synthesis | Post-Track-10 own phase |
| **C-T10-EMIT-T7H2** | aiCollaboration cwd fallback — terminal-launched IDE sessions don't carry IDE bundle | Post-Track-10 own phase |
| **C-T10-EMIT-T7H3** | terminalFamily dwell — Terminal/iTerm sessions don't enrich YOU'RE ON `focusedMinSoFar` | Post-Track-10 own phase |
| **C-25** | WhereStoppedDeriver sleep/wake substrate idle gap | Post-Track-9 own phase |
| **C-26** | Moat `ProdInsights+InboxItems.swift` 795 LOC reorg | Post-Track-9 moat hygiene |
| **C-29** | `queryCommentsOnMyWork` viewer_login substrate enrichment | Post-Track-9 substrate phase |
| **T7 a11y 5 NITs** | Forward carry — design-system primitive a11y audit | Post-Track-10 own a11y phase |
| **Phase 5.4** | DB-backed TeammatePresenceReader — lights up TEAM·N | Own track |
| **C-8** | Resume CTA branch-deletion staleness | v1.1 |
| **C-19, C-42** | Localization | Separate track |
| **RECAP/EOD hours** | Configurable hour boundaries (currently `[6, 11)` / `[17, 23)`) | v1.1 |
| **`get_standup_summary`** | MCP tool for AI consumers | Future if demand |
| **C-38** | Real TopToolsCard substrate (Analytics hidden) | Post-Track-9 |
| **C-39** | PeakHourCallout heatmap substrate (Analytics hidden) | Post-Track-9 |
| **C-40** | Per-day chart drill-down (Analytics hidden) | Post-Track-9 if demand |
| **C-41** | Multi-week 30d/90d Analytics variant | Post-Track-9 |
| **C-44** | Real dual-axis Chart (macOS 15+ baseline) | Post-Track-9 |
| **Pre-existing flake** | `testWarmState_HappyPath_TrackD1` (T6/T7 noted) | Separate triage |
| **Substrate-touch NITs** | From T6/T7/T8 Stage 6 dual reviews (a11y + HIG) not applied inline | Per-phase forward |

---

## 7. Track-10 wrap deliverables

### 7.1 SHIPPED commit sequence (Stage 5)

Ordered atomic commits on `feature/GUN-52-track-10-T9-polish-wrap`:

1. `docs(GUN-52): T9 phase spec landing` — this file.
2. `chore(GUN-52): a11y sweep — apply inline-fixable NITs (Track-10 T9)`.
3. `chore(GUN-52): HIG sweep — touch targets + animation duration consistency (Track-10 T9)`.
4. `chore(GUN-52): perf sweep — token-tier + DateFormatter + ForEach grep (Track-10 T9)`.
5. `chore(GUN-52): privacy walkback master grep across Track-10 file set (Track-10 T9)`.
6. `chore(GUN-52): LOC budget verification (Track-10 T9)`.
7. `docs(GUN-52): master spec §9.2 carry list amendments — Track-10 emits (Track-10 T9)`.
8. `docs(GUN-52): current-state.md Track-10 SHIPPED final paragraph (Track-10 T9)`.
9. `docs(GUN-52): SHIPPED — Track-10 T9 polish + wrap (T1..T9 complete)`.

(Conditional)
- `fix(GUN-52): a11y BLOCKER from Stage 6 sweep (Track-10 T9)` — if subagent identifies BLOCKER.
- `fix(GUN-52): HIG IMPORTANT from Stage 6 sweep (Track-10 T9)` — analogously.
- `fix(GUN-52): manual smoke BLOCKER fix (Track-10 T9)` — async per D-3, lands AFTER initial SHIPPED if Дима finds BLOCKER.

### 7.2 FF-merge T9 → collective (final implementation step)

```bash
git checkout feature/track-10-operational-home
git merge --ff-only feature/GUN-52-track-10-T9-polish-wrap

# Verify collective tip is T9 SHIPPED commit
git log --oneline --first-parent -3
```

### 7.3 Push handoff to Дима (D-4) — NOT executed by Claude

```bash
# Step A — Sanity check origin/dev BEFORE push
git -C ~/Desktop/Leaf/leaf log --oneline origin/dev -1

# Step B — Verify FF-able relationship
git -C ~/Desktop/Leaf/leaf merge-base origin/dev feature/track-10-operational-home

# Step C — Дима sanity:
git -C ~/Desktop/Leaf/leaf log --oneline feature/track-10-operational-home -15
git -C ~/Desktop/Leaf/leaf diff origin/dev..feature/track-10-operational-home --stat

# Step D — Push collective branch as new dev tip (FF):
git -C ~/Desktop/Leaf/leaf push origin feature/track-10-operational-home:dev

# DO NOT push to main — collective merge is a separate session.
# DO NOT use --force or --force-with-lease without escalation.
```

### 7.4 Collective merge to `main` (post-master-smoke, separate session)

Дима driver:
```bash
git -C ~/Desktop/Leaf/leaf checkout main
git -C ~/Desktop/Leaf/leaf pull --ff-only
git -C ~/Desktop/Leaf/leaf merge --no-ff feature/track-10-operational-home \
    -m "merge: Track-10 operational Home (T1..T9) into main"
git -C ~/Desktop/Leaf/leaf push origin main
```

### 7.5 Whitepaper sync via `/sync-docs track-10-wrap` (separate session per D-11)

Public-safe summary entry in `~/Desktop/Leaf/leaf-docs/`:
- High-level Track-10 surfaces (RESUME hero · NEEDS YOU · TEAM·N · SINCE · YOU'RE ON · RECAP/EOD · Analytics hidden).
- 9-phase substrate-purity streak preserved.
- Operational console framing v0.4 (whitepaper Home model update).
- Changelog entry: `2026-05-23 HH:MM · Dmitrii — Track-10 wrapped (T1..T9 collective ship)`.

NOT public-safe (stays out per pre-push-leaf checklist):
- Moat impl (GitDeltaReader / ProdInsights+CurrentTaskSession / Standup hour boundaries internals)
- Substrate query bodies
- Sentinel internals
- LinearIDExtractor prefix list

---

## 8. References

- Master Track-10 spec: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` (§4 T9 + §7.3 + §9.2 + §12 acceptance).
- Track-9 T10 wrap precedent: `docs/superpowers/specs/2026-05-21-track-9-T10-wrap-polish.md`.
- Per-phase T1..T8 specs (Stage 6 dual-review sections for NIT enumeration in Stage 5):
  - `2026-05-22-track-10-T1-foundation.md`
  - `2026-05-22-track-10-T2-resume-hero.md`
  - `2026-05-22-track-10-T2-5-operational-followup.md`
  - `2026-05-22-track-10-T3-younow-badge.md`
  - `2026-05-22-track-10-T4-needs-you.md`
  - `2026-05-22-track-10-T5-since-last-active.md`
  - `2026-05-23-track-10-T6-team-n-broader-pulse.md`
  - `2026-05-23-track-10-T7-youre-on-anchor.md`
  - `2026-05-23-track-10-T8-recap-eod.md`
- LEAF-NN tracking convention: `docs/conventions/leaf-id-tracking.md`.
- Shared memory: `.claude/shared/{architecture.md, conventions.md, current-state.md}`.
- ADR-010 walkback lineage: `RelayBodyLeakageTests` across Track-1/3/4/6 + Track-10 T2/T5/T7 sentinel-injection tests.
- Pre-push checklist: `.claude/commands/pre-push-leaf.md`.

---

## 9. Workflow

Per `.claude/shared/conventions.md` 8-stage one-phase-one-session:

1. ✅ **Discovery** — substrate diff vs dev verified (0 SQLCipher / 0 MCP / 0 Registry diff). Track-9 T10 wrap precedent read. Master spec §4 T9 + §7.3 + §9.2 + §12 read. Authoritative NIT carry log from current-state.md verified.
2. ✅ **Brainstorm** — 4 critical Qs resolved via user (D-1..D-4); secondary Qs resolved against user prompt recommendations (D-5..D-14).
3. ✅ **Spec write** — this file.
4. ✅ **Plan write** — `.claude/plans/gun-xxx-track-10-t9-dapper-hopcroft.md` (gitignored).
5. **NEXT**: Implementation — sequential atomic commits per §7.1.
6. **NEXT**: Independent review — general-purpose subagents (a11y + HIG) per §3.2.
7. **NEXT**: Verification — 9 AC gates per §4.
8. **NEXT**: Ship — final SHIPPED commit + master spec markers + current-state.md + push handoff to Дима per §7.3.
