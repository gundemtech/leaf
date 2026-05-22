# Track-9 T10 — Wrap + polish + verification

**Status:** IN PROGRESS — Stage 3 spec written.
**Parent:** `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md` master spec.
**Branch:** `feature/track-9-substrate` (off T9 SHIPPED tip `316298f0`).
**Owner:** dima + Claude.
**Date:** 2026-05-21.

---

## 1. Scope

Track-9's 10th and **final** phase. Polish + verification + Track-9 collective wrap. Closes master spec §T10 (lines 222-229) + 13 accumulated carries (C-22 / C-24 / C-27 / C-28 / C-30 / C-31 / C-32 / C-33 / C-34..C-37 + design-system primitive a11y carry-forwards from P9).

After T10 SHIPPED → `feature/track-9-substrate` ready for collective merge to `main` (162 commits ahead).

**Deliverables:**
1. A11y sweep (general-purpose subagent as reviewer) — BLOCKERS fixed inline.
2. HIG sweep manual — Дима driver, я observe.
3. Perf sweep automated — `check-tokens` 3-tier + DateFormatter cache grep + ForEach.indices grep.
4. C-24 — drop orphan `InsightsSnapshot.recentActivity` field + `InsightsReader.refresh()` fetch (~200 rows/tick serialized for zero consumers).
5. C-22 — verify zero new `formatRelative` duplicates in T5..T9 view layer (HomeRelativeTimeFormatter already exists from P9).
6. T8 review polish bundle — C-27 (MAX(failure) doc-fix), C-28 (xcode:// fictional → deriver returns nil), C-30 (cutoff constants extraction), C-31 (projectPath → projectIdentifier rename), C-32 (liveMeeting ms-collision doc), C-33 (test assertion).
7. Master spec §T9 wording amendments C-34..C-37 + §9.3 integration of T9 carries C-38..C-44.
8. Manual smoke per master spec §3 mockup parity (Дима driver).
9. Track-9 wrap deliverables — current-state.md update + ship-prep collective merge command (NOT pushed — Дима sanity check + push) + whitepaper sync via `/sync-docs track-9-wrap`.

### 1.1 Out of scope (hard exclusion)

- **C-25** (WhereStoppedDeriver sleep/wake idle gap, post-T7 discovery) — post-Track-9 own phase. Rationale: substrate bug fix in moat `ProdWhereStoppedDeriver` requires own brainstorm (3 fix directions per master spec §9.1.C-25 lines 421-424) + sentinel-injection regression test for new code paths in Track-1 D3 substrate. Not blocking Track-9 ship — T7 UI verified to render correctly when substrate returns nil; WHERE STOPPED card stays on honest empty state for the closed-laptop scenario until C-25 substrate fix lands. Documented in master spec §9.1.C-25 (lines 401-430) + carry to post-Track-9 backlog.
- **C-26** (moat `ProdInsights+InboxItems.swift` 795 LOC > 700 budget) — moat hygiene only, no public surface impact, doesn't block ship. Post-Track-9 moat reorg phase.
- **C-29** (`queryCommentsOnMyWork` viewer_login filter anticipatory) — substrate enrichment (touches collector payload extension). Post-Track-9.
- **C-38..C-44** (T9 carries: real TopToolsCard / heatmap PeakHour / drill-down / multi-week / localization / view tests / dual-axis Chart) — integrated as §9.3 entries, not addressed in T10. Post-Track-9 phases.
- **Phase 5.4** (WITH YOU ON THIS DB-backed reader) — out of Track-9 entirely.
- **Phase 5.6** (offline footer + relay status) — out.
- **v1.1 deferred** — C-8 (branch staleness via git CLI) — out.
- **Localization track** — C-19 + C-42 — out.

---

## 2. Decisions taken (Stage 2 brainstorm self-conducted)

**D-1.** **C-25 deferred to post-Track-9 own phase.** Three fix directions in master spec §9.1.C-25 require dedicated brainstorm. Substrate moat touch needs sentinel test. Closed-laptop is dominant case but T7 UI degrades gracefully → ship Track-9 with documented limitation.

**D-2.** **T8 carries C-27/C-28/C-30/C-31/C-32/C-33 land in T10.** Trivial doc-fixes (C-27/C-30/C-32), nil-deriver (C-28), public rename (C-31), missing test (C-33).

**D-3.** **C-31 rename `projectPath` → `projectIdentifier`** in `InboxSourceContextRef.xcodeBuild`. Breaking public API but contained — 1 moat callsite + 2 test cases. Honest naming aligns with substrate emit shape (NAME not path).

**D-4.** **C-28 xcode:// fictional URL** → deriver returns nil + doc-comment. Enum case kept (no breaking change), but `InboxSourceURLDeriver.synthesize(.xcodeBuild(...))` always returns nil. Honest no-op — INBOX row stays non-tappable until real macOS LSScheme deep-link mechanism lands. Pairs with C-31 rename.

**D-5.** **C-24 drop full surface, not just orphan check.** Verified via Discovery: LeafMCP has ZERO refs (current-state.md claim "RecentActivityTool keeps own path" — fictitious, no such tool in `LeafMCP/Tools/` inventory). Drop:
- `DerivedInsights.recentActivity(period:limit:)` protocol method + default extension
- `InsightsSnapshot.recentActivity: [ActivityFeedEntry]` field + 2 init params + isEmpty check
- `InsightsReader.refresh()` line 149 fetch + line 256 assignment
- `ActivityFeedEntry` type itself **stays** (consumed by `LeafMCP/Tools/QueryActivityTool.swift` etc. via own paths).

**D-6.** **Master spec §T9 wording amendments C-34..C-37** inline at lines 217-218. §9.3 integration of T9 carries C-38..C-44 at master spec §9.3 list (replaces existing inline T9 spec §9.2 entries with master spec §9.3 final inventory).

**D-7.** **Track-9 collective merge to main** — `--no-ff` preserving 162-commit history (per-phase SHIPPED commits remain navigable via `git log --first-parent`). Command **prepared but NOT executed** by Claude. Дима sanity check + push.

**D-8.** **Whitepaper sync** via `/sync-docs track-9-wrap` slash-command in Stage 8. Public-safe summary only (Track-9 cycle 10 phases / 9-phase substrate-purity streak / sentinel discipline preserved). Implementation moat stays out.

**D-9.** **A11y sweep via subagent**, HIG sweep manual (Дима clicks), perf sweep automated. P9 precedent.

**D-10.** **Multiple atomic commits per T10** vs single bundled commit. Per-task isolation aids debugging if regression detected post-ship.

---

## 3. Architecture

T10 is polish + cleanup + spec doc updates. **No new architecture.** Zero new substrate.

### 3.1 Substrate-purity invariant

| Surface | Pre-T10 | Post-T10 | Delta |
|---|---|---|---|
| SQLCipher tables | 30 (M001-M018 + M024 + M026 + M027) | 30 | 0 |
| event_kinds | T9 baseline (incl. 198 ShareEventTypeKey) | same | 0 |
| ShareEventTypeKey registry | 198 | 198 | 0 |
| MCP tools | 15 (12 low-level + 3 structured) | 15 | 0 |
| DerivedInsights protocol methods | 23+ | 22+ (drops `recentActivity`) | **-1 (reduces surface)** |
| InsightsSnapshot fields | N (incl. `recentActivity`) | N-1 (drops `recentActivity`) | **-1 (reduces surface)** |
| InboxSourceContextRef cases | 13 | 13 | 0 (renames param only) |

**Track-9 substrate-purity streak: 9 phases T1-T9 zero-conflict + T10 reduces surface (drops orphan).** Verified diff against `main`: no new tables / event_kinds / MCP tools / registry entries.

### 3.2 Per-carry implementation

#### 3.2.1 C-24 — drop `recentActivity` orphan

11 line-changes across 3 files. Sequential edit:

1. `Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift` — remove protocol method (line 129) + extension default (line 226).
2. `Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift` — remove field (line 101), Phase 4.10.A docs comment (line 278), 2 init params (lines 210 + 312), 2 init assignments (lines 257 + 360), `isEmpty` clause (line 393).
3. `Leaf/Models/InsightsReader.swift` — remove fetch call (line 149), assignment (line 256).

No test file changes (zero existing tests reference `recentActivity`).

#### 3.2.2 C-28 — `xcodeBuild` URL deriver returns nil

Edit `Packages/LeafCore/Sources/LeafCore/Insights/InboxSourceURLDeriver.swift` `.xcodeBuild` case:

```swift
case .xcodeBuild:
    // C-28: xcode:// is a fictional URL scheme — no registered macOS LSScheme.
    // NSWorkspace.shared.open() would fail silently. Until a real Xcode deep-link
    // mechanism lands, INBOX rows for xcode build events stay non-tappable
    // (sourceURL = nil → row renders without tap target per T8 baseline).
    return nil
```

Update 2 tests in `InboxSourceURLDeriverTests.swift` to assert nil return for both `.xcodeBuild(projectIdentifier: ...)` and `.xcodeBuild(projectIdentifier: nil)`.

#### 3.2.3 C-31 — `projectPath` → `projectIdentifier`

Public API rename in `InboxSourceContextRef.swift`:

```swift
case xcodeBuild(projectIdentifier: String?)
```

Callsite update in `ProdInsights+InboxItems.swift:585-589` (moat, gitignored): `synthesize(.xcodeBuild(projectIdentifier: project))`.

Test update in `InboxSourceURLDeriverTests.swift` (lines 72 + 77).

#### 3.2.4 C-27 — `MAX(failure)` semantic doc-fix

Moat `queryCIFailed` SQL comment update: clarify "highest in-window failure count per (repo, sha) pulse aggregation" (current ambiguity — reads like "currently failing"). Doc-only change to header comment of `queryCIFailed` method.

#### 3.2.5 C-30 — Cutoff constants extraction

Moat `ProdInsights+InboxItems.swift` — extract hardcoded cutoffs (8h build / 24h CI / 4h meeting / 14d D3) to named `private static let` block at top of struct. Improves readability without behavior change.

#### 3.2.6 C-32 — `liveMeeting` ms-collision doc

Moat `queryLiveMeeting` comment update: acknowledge same-millisecond start collision edge case (extremely rare — would require 2 zoom meetings starting at exact same ms). Document as known limitation; post-Track-9 substrate enrichment could generate UUID-based `meeting_id` for true uniqueness.

#### 3.2.7 C-33 — `.alerts.rawValue` test assertion

`InboxFilterValuesTests` or similar (T8 added). Add assertion for `.alerts.rawValue == "alerts"` (parity with `.all` / `.reviews` / `.questions` / `.mentions`).

#### 3.2.8 C-22 sweep — verify no new duplicates

`grep -rn "DateFormatter()" Leaf/Views/Window/{Home,Analytics}` expect 0 hits.
`grep -rn "func formatRelative\|HomeRelativeTimeFormatter.format" Leaf/Views/Window/{Home,Analytics}` expect:
- 1 direct usage (WhereStoppedBlock line 138)
- 2 thin wrappers (WithYouOnThisBlock line 187-189, YouNowBlock line 300-302) — both intentional per P9 carry decision
- Track-9 view files: zero new direct DateFormatter() calls (T9 added 2 static cached formatters in WeekChipStrip — pattern OK)

#### 3.2.9 Master spec amendments

`docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md`:
- **§T9 line 217 wording:** "8 day chips" → "7 day chips (substrate fidelity per T4 D-8 — `WeeklyMetrics.dailySeries` ships 7 entries; T9 amendment carry C-35)". Drop `TopToolsCard` → `TopToolsPlaceholder` (substrate gap C-38 — T6 SurfacePill discriminator coupling). Drop "24h mini-heatmap" → "24-dot Capsule strip (substrate ships `peakHour: Int?` only; full distribution carry C-39)".
- **§T9 line 218:** "InsightsSnapshot.weeklyMetrics: WeeklyMetrics?" → "InsightsSnapshot.weeklyMetrics: WeeklyMetrics = .empty defaulted (T4 substrate ships `.empty` first-class — defaulted-init blast-radius parity with P3 todayMetrics)".
- **§9.3 carry list extension:** integrate T9 carries C-38..C-44 + Stage 6 review additions.

### 3.3 Sweeps shape

| Sweep | Mechanism | Driver | Output |
|---|---|---|---|
| A11y | general-purpose subagent acting as a11y reviewer | Claude dispatches read-only | BLOCKER fix inline / IMPORTANT cheap-fix / NIT carry |
| HIG | Manual visual inspection | Дима clicks tabs | Side-by-side screenshots vs HIG checklist |
| Perf | Automated grep + check-tokens | Claude | Pass/fail gate |
| Manual smoke | Visual click-through per master spec §3 | Дима clicks | Documented deviations (WHERE STOPPED empty per C-25 / WITH YOU empty per Phase 5.4) |

---

## 4. Acceptance gates (Stage 7 verification)

10 gates parallel to T7/T8/T9 acceptance discipline:

1. **AC-1** — 5/5 xcodebuild schemes Debug SUCCESS: LeafCore / LeafCorePrivate / Leaf / LeafAgent / LeafMCP.
2. **AC-2** — SPM tests green: XCTest + Swift-Testing combined, 0 failures, ±0..±2 delta vs T9 baseline (2990 + 45 = 3035). recentActivity drop: no test refs to remove (Discovery verified zero refs in LeafCoreTests). C-33 +1 test assertion. C-31 test param rename +0 test count. Expected: ~3036 total.
3. **AC-3** — `just check-tokens` 3-tier clean (BASE / MIGRATION / RETIRED all pass).
4. **AC-4** — Substrate diff vs main: `git diff main -- Packages/LeafCore/Sources/LeafCore/DB/` empty (no new migrations).
5. **AC-5** — Registry diff vs main: `git diff main -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift` shows Track-9 net (+3 from baseline 195 → 198), no T10 delta.
6. **AC-6** — MCP diff vs main: `git diff main -- LeafMCP/` shows Track-9 net (0 new tools), no T10 delta.
7. **AC-7** — Privacy walkback narrow grep: `grep -rnE "absolute_path|full_comment_body|raw_email|notes_body|email_subject|note_body|file_contents|raw_prompt|tool_input|tool_response|response_body|prompt" <T10 touched files>` → 0 hits.
8. **AC-8** — LOC budgets preserved: HomeView ≤ 280 (no T10 touch), WhereStoppedBlock ≤ 160 (no T10 touch), TodayBlock LOC preserved, AnalyticsView ≤ 120 (no T10 touch), InboxBlock + InboxItemRow + InboxFilterRow preserved.
9. **AC-9** — A11y sweep BLOCKERS all addressed (NITs documented in §6 carries).
10. **AC-10** — Master spec §9.1 + §9.3 final markers (T10 close-out updates inline).

Manual smoke (§3 mockup parity) — separate Stage 7 manual run, blocking on Дима availability.

---

## 5. Testing strategy

### 5.1 No sentinel-injection regression test

T10 = polish + cleanup + docs. No new payload field reads. No new privacy surface. Sentinel-injection test pattern (T1/T2/T3/T7/T8 lineage) NOT required for T10 per master spec §6 line 285 precedent (P3/P4/P5/P7 same exemption).

C-28 deriver change reduces URL synthesis surface (returns nil → less data assembly). C-24 drops field that never carried body text (aggregated activity feed entries). Privacy posture strictly improves or stays neutral.

### 5.2 Test deltas

- **C-24**: 0 new tests (drops production code only, zero test refs to update per Discovery).
- **C-28**: 2 updated tests (InboxSourceURLDeriverTests `xcodeBuild` cases assert nil return).
- **C-31**: 2 updated tests (same file, param name change in call).
- **C-33**: +1 new test assertion (`InboxFilterValuesTests` for `.alerts.rawValue`).
- Other carries: 0 test delta (doc-only changes).

Expected net: **+1 new** assertion.

### 5.3 Verification commands

```bash
# AC-1
xcodebuild -scheme LeafCore -configuration Debug build
xcodebuild -scheme LeafCorePrivate -configuration Debug build
xcodebuild -scheme Leaf -configuration Debug build
xcodebuild -scheme LeafAgent -configuration Debug build
xcodebuild -scheme LeafMCP -configuration Debug build

# AC-2
cd Packages/LeafCore && swift test 2>&1 | tail -20

# AC-3
just check-tokens

# AC-4..AC-6
git diff main -- Packages/LeafCore/Sources/LeafCore/DB/ | wc -l  # expect 0
git diff main -- Packages/LeafCore/Sources/LeafCore/Share/ShareEventTypeRegistry.swift | wc -l  # expect Track-9 net delta
git diff main -- LeafMCP/ | wc -l  # expect 0 (LeafMCP unchanged Track-9)

# AC-7
grep -rnE "absolute_path|full_comment_body|raw_email|notes_body|email_subject|note_body|file_contents|raw_prompt|tool_input|tool_response|response_body" \
    Leaf/ Packages/LeafCore/Sources/LeafCore/Insights/InboxSource*.swift Packages/LeafCore/Sources/LeafCore/Insights/InsightsSnapshot.swift Packages/LeafCore/Sources/LeafCore/Insights/DerivedInsights.swift
# expect 0 hits

# Perf sweep
grep -rn "DateFormatter()" Leaf/Views/Window/Home Leaf/Views/Window/Analytics  # expect 0
grep -rn "ForEach.*indices\b" Leaf/Views/Window/Home Leaf/Views/Window/Analytics  # expect 0
```

---

## 6. Carry-overs (post-Track-9 backlog after T10)

After T10 SHIPPED, the following carries remain post-Track-9 (master spec §9.3 final inventory):

| Carry | Description | Owner |
|---|---|---|
| **C-5** | LocalAppsStore reactivity | Post-Track-9 small refactor |
| **C-8** | Resume CTA branch-deletion staleness | v1.1 |
| **C-10** | WithYouOnThisBlock empty CTA N count | Phase 5.4 |
| **C-11** | Offline/stale footer | Phase 5.6 |
| **C-12** | Row tap routes to Team tab w/o teammate selection | Phase 5.4 |
| **C-13** | `TeammateMatch.durationSec` hardcoded | Phase 5.4 |
| **C-19** | Localization | Separate track |
| **C-25** | WhereStoppedDeriver sleep/wake idle gap | **Post-Track-9 own phase** (T10 §1.1 D-1) |
| **C-26** | Moat `ProdInsights+InboxItems.swift` 795 LOC reorg | Post-Track-9 moat hygiene |
| **C-29** | `queryCommentsOnMyWork` viewer_login filter | Post-Track-9 substrate enrichment |
| **C-38** | Real TopToolsCard substrate | Post-Track-9 substrate phase |
| **C-39** | PeakHourCallout heatmap substrate | Post-Track-9 |
| **C-40** | Per-day chart drill-down | Post-Track-9 if demand |
| **C-41** | Multi-week 30d/90d variant | Post-Track-9 |
| **C-42** | Localization (T9 specific) | Separate track |
| **C-43** | View-layer test coverage | Codebase precedent skip / opportunistic |
| **C-44** | Real dual-axis Chart | macOS 15+ baseline or custom ChartContent |
| Track-9 net | AI subagent failure detector | Phase 4.9 |
| Track-9 net | VSCode/JetBrains AX line capture | Post-Track-9 IDE family |
| Track-9 net | AI rollup + Mode classifier + Latency stats Analytics | Post-Track-9 Analytics expansion |
| Track-9 net | Slack DM bucket routing | Conditional |
| Track-9 net | `get_weekly_metrics` MCP tool | Future |
| Track-9 net | T5 multi-window editor accuracy | Post-Track-9 IDE family |
| Plus T8 net | Inbox placeholder substrate (Calendar / Mail / Reminders / Slack DM) | Each = own phase post-Track-9 |

A11y carry-forwards (from P9 + T10):
- Design-system primitive a11y audit (LeafPill / LeafInput / LeafIconChip as Button labels)
- Pluralization helpers
- Per-block hint/label semantic refinement (if subagent identifies NITs)

---

## 7. Track-9 wrap deliverables

### 7.1 SHIPPED commit sequence

Ordered atomic commits on `feature/track-9-substrate`:

1. `docs(track-9-T10): spec landing` — this file.
2. `fix(track-9-T10): C-24 drop recentActivity orphan field` — DerivedInsights + InsightsSnapshot + InsightsReader.
3. `fix(track-9-T10): C-28 InboxSourceURLDeriver xcodeBuild returns nil (fictional scheme)` — deriver case + test assertions.
4. `refactor(track-9-T10): C-31 InboxSourceContextRef.xcodeBuild projectPath → projectIdentifier` — enum + moat callsite + tests.
5. `test(track-9-T10): C-33 InboxFilterRow .alerts.rawValue assertion` — test addition.
6. `fix(track-9-T10): C-27 + C-30 + C-32 moat polish bundle` — moat doc-comments + constants extraction (LOCAL-ONLY, gitignored).
7. (Conditional) `fix(track-9-T10): a11y BLOCKER fixes from Stage 6 sweep` — if subagent identifies.
8. `docs(track-9-T10): master spec §T9 wording amendments C-34..C-37 + §9.3 integration C-38..C-44`.
9. `docs(track-9-T10): SHIPPED — Track-9 wrapped, T1..T10 complete` — current-state.md + master spec final markers.

### 7.2 Collective merge prep (NOT executed)

Command prepared for Дима:
```bash
git -C ~/Desktop/Leaf/leaf checkout main
git -C ~/Desktop/Leaf/leaf pull --ff-only
git -C ~/Desktop/Leaf/leaf merge --no-ff feature/track-9-substrate \
    -m "merge: Track-9 substrate enrichment (T1..T10) into main"
# Sanity check git log, then:
git -C ~/Desktop/Leaf/leaf push origin main
```

Дима reviews + executes manually.

### 7.3 Whitepaper sync via `/sync-docs track-9-wrap`

Public-safe summary entry in `~/Desktop/Leaf/leaf-docs/`:
- High-level Track-9 architecture: 10 phases (T1-T9 substrate + T9 UI + T10 polish + wrap)
- 9-phase substrate-purity streak preserved
- Sentinel-injection regression discipline per ADR-010
- Net public deliverables: substrate enrichment for YOU·NOW depth + Analytics surface + INBOX full + WHERE STOPPED 4-line + Linear/GitHub new event_kinds
- Changelog entry: `2026-05-21 HH:MM · Dmitrii — Track-9 wrapped (T1..T10 collective ship to main)`

NOT public-safe (stays out per pre-push-leaf checklist):
- LOC budgets in moat
- Moat impl details (SQL strings, regex patterns)
- Sentinel test internals
- Branch name parsing regex

---

## 8. References

- Master Track-9 spec: `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md`.
- T7 spec: `docs/superpowers/specs/2026-05-21-track-9-T7-where-stopped-4line.md`.
- T8 spec: `docs/superpowers/specs/2026-05-21-track-9-T8-inbox-feeder-expansion.md`.
- T9 spec: `docs/superpowers/specs/2026-05-21-track-9-T9-analytics-ui.md`.
- Track-8 P9 polish spec (precedent): `docs/superpowers/specs/2026-05-19-phase-8-9-polish.md`.
- Architecture / conventions / current-state: `.claude/shared/`.
- ADR-010 walkback lineage: `RelayBodyLeakageTests` across Track-1/3/4/6.

---

## 9. Workflow

Per `.claude/shared/conventions.md` 8-stage one-phase-one-session:

1. ✅ Discovery — completed via Bash greps (LeafMCP zero recentActivity refs, InboxSourceContextRef shape, T10 spec/plan doesn't exist).
2. ✅ Brainstorm — self-conducted, 12 Q answered with self-verify, decisions D-1..D-10 above.
3. ✅ Spec write — this document.
4. NEXT: Plan write — `.claude/plans/track-9-T10.md` (gitignored).
5. Implementation — sequential atomic commits per §7.1.
6. Independent review — general-purpose subagent acting as code-reviewer + a11y reviewer.
7. Verification — 10 AC gates per §4.
8. Ship — final SHIPPED commit + master spec markers + current-state.md + collective merge prep + whitepaper sync.
