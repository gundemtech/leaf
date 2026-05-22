# Track-10 T2.5 — operational follow-up (post-T3 smoke fix bundle)

**Status**: Stage 3 (per-phase spec) closed and SHIPPED in the same calendar
session — fixes were small enough that planning, implementation, and ship
ran end-to-end on 2026-05-22.

**Branch**: `feature/track-10-T2-5-operational-followup` (off
`fix/dev-launch-reliability` tip `f7d3c5f1` — Track-10 T1+T2+T3 merged).

**Phase nomenclature** — "T2.5" = bug-fix bundle authored AFTER T3 SHIPPED
that closes substrate gaps in already-SHIPPED T1 and T2, surfaced during
real-data Home smoke on Dima's Mac. Chronological author order is
T1 → T2 → T3 → T2.5; the half-step name reflects the fact T2.5 patches T1
and T2, not that it sits between them in time. T3 SHIPPED clean and was
not touched.

**Master spec contract**: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` — no master spec wording change (T2.5 is an in-place T1+T2 amendment).

**T1 + T2 spec amendments**:
- T1 §11 — switches counter gap closure.
- T2 §7 — RESUME hero blank-shell + workspace fallback closure.

---

## 1. Context

Real-data Home dashboard smoke on Dima's Mac (post-T3 SHIPPED, Fri 2026-05-22, ~5h workday) surfaced two substrate-level bugs in T1 + T2 that the smoke tests in those phases didn't catch:

1. **TODAY · switches counter = 853** (UX-target ~10-30). T1 C3 patch reduced 58k → 853 (70× win, dimensionally correct) but the new query had **no min-hold gate** — it counted every distinct attention bundle transition, including rapid Cmd-Tab flickers. The post-T1 query body explicitly acknowledged the omission ("skips the rate division and the min-hold gate"). T1's promised "~10-30 expected" range was never delivered.
2. **RESUME hero rendered blank shell** when `taskIdentity != nil && !isEmpty && linearID == nil && branch == nil && snapshot.excerpt == ""`: `taskLine` joined an empty `parts` array to `""`, then the `else if isEmpty == true` branch was FALSE, so emptyState was skipped. Net: a card with header + nothing under it.

Plus a substrate cousin of bug 2: when the frontmost bundle was Leaf.app itself, `currentWorkspacePath()` resolved `tech.gundem.leaf` against `WorkspacePathResolver` and got nil — so `GitDeltaReader.read(nil)` returned nil — so WIP line and Diff CTA were hidden even when a fresh Xcode workspace event was minutes old in attention history.

Both bugs reproduce on every real Mac with a realistic workflow (Cmd-Tab churn + occasional dwell on Leaf.app). Without T2.5, T1+T2's user-visible promise — "operational Home that actually shows what you're doing right now" — degrades to "operational Home that shows nothing once you look at it".

T2.5 ships **zero substrate-shape change**: no new event_kinds (registry 198 preserved) · no SQLCipher migrations · no MCP tools · no public API additions on LeafCore (existing `currentWorkspacePath()` and `switchCount` semantics get more accurate impls behind unchanged contracts). T2.5 is sentinel-injection EXEMPT — no new payload reads; existing T2 sentinel test continues to fence the gitDelta surface.

---

## 2. Goal + scope

Three precise fixes + two spec amendments:

| # | Surface | Change | Files |
|---|---|---|---|
| **F1** | moat — switches counter | Add `min_hold_ms` gate (60_000 ms) on destination dwell via SQL window function; tunable constant `contextSwitchMinHoldMs` in moat. | `ProdInsights+TodayMetrics.swift` + tests |
| **F2** | public view — render bug | `taskLine` becomes `@ViewBuilder`-gated on `parts.isEmpty`; cardContent's emptyState condition reads `taskLineHasVisibleContent(_:)` instead of `taskIdentity == nil OR isEmpty == true`. Eliminates blank shell. | `ResumeHeroBlock.swift` |
| **F3** | moat — workspace fallback | `currentWorkspacePath()` returns frontmost-resolved path; on nil, falls back via `resolveMostRecentIDEWorkspacePath()` — distinct recent attention bundles ordered by `MAX(ts) DESC`, first resolvable wins; 24h lookback cap. | `ProdInsights+CurrentTaskIdentity.swift` + tests |

3 implementation commits + 1 spec-amend commit + 1 T2.5 spec landing commit. F1 and F3 are moat-only (gitignored per `.gitignore:42-49`); only F2, the amend, and this spec produce public commits.

---

## 3. F1 — switches counter min-hold gate

### 3.1 SQL change (moat)

`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+TodayMetrics.swift` — `queryAttentionTransitionsCount` extended with a destination-dwell gate via a window-function predicate. Threshold sourced from a private `contextSwitchMinHoldMs: Int64 = 60_000` constant in the same moat extension. Implementation body lives in `LeafCorePrivate`; this spec describes only the semantic.

**Semantic**: transition `prev → curr` counts when `curr` held foreground ≥ 60s before the next event, OR `curr` is the latest event in the window (open dwell — user is still on it). Brief Cmd-Tab glances to Slack and back don't count; the return-to-IDE leg still does because the IDE's own dwell qualifies.

### 3.2 Tests

`ProdInsightsTodayMetricsSwitchesTests.swift` extended with 4 new fence tests + comment refresh on the existing at-threshold test:

- `testSwitchCount_counts_distinctBundleTransitions` — existing 5-event seed at 60s spacing. Comment updated from "well above threshold" to "exactly at threshold, exercises inclusive `>=` bound".
- `testSwitchCount_flicker_isRejected` — `A@0, B@30_000, A@45_000`. B's dwell = 15s < threshold → rejected; A's open dwell → counted. Expect 1.
- `testSwitchCount_dwellJustBelowThreshold_rejects` — `A@0, B@1, A@T`. B's dwell = T − 1 = 59_999 ms → rejected. Expect 1.
- `testSwitchCount_dwellAtThreshold_counts` — `A@0, B@1, A@(T + 1)`. B's dwell = T → inclusive `>=` accepts. Expect 2.
- `testSwitchCount_lastEventOpenDwell_isCounted` — `A@0, B@30_000`. B is the last row → open dwell → counted. Expect 1.

Each fence test includes a per-row dwell walkthrough in the test docstring to prevent off-by-semantic regressions.

### 3.3 Why min-dwell-on-destination

Brainstorm Q1 — confirmed by user in planning session. Simpler SQL (no Swift state machine). Maps to UX intent: "I switched to app X and stayed there" reads as a real switch. Edge case — return-to-base `A → B(<60s) → A` over-counts the B→A leg by 1 because A holds. Risk-accept; tune via release smoke; carry to sustained-state-machine option if telemetry surfaces over-count.

---

## 4. F2 — RESUME hero render-bug

### 4.1 View changes

`Leaf/Views/Window/Home/Blocks/ResumeHeroBlock.swift`:

- New static `taskLineHasVisibleContent(_:)` predicate: returns true iff `id.linearID != nil || id.branch != nil`. Used by both the render gate and the emptyState fall-through.
- `taskLine` becomes `@ViewBuilder` and guards on `parts.isEmpty` (belt-and-suspenders for future callers that bypass `cardContent`).
- `cardContent`'s first `if let taskIdentity, !taskIdentity.isEmpty` becomes `if let taskIdentity, Self.taskLineHasVisibleContent(taskIdentity)`.
- The `else if` becomes `else if !Self.taskLineHasVisibleContent(taskIdentity)`.

### 4.2 Behavior matrix

| taskIdentity | linearID | branch | snap.excerpt | Pre-T2.5 | Post-T2.5 |
|---|---|---|---|---|---|
| nil | — | — | empty | emptyState | emptyState |
| isEmpty | — | — | empty | emptyState | emptyState |
| `{workspacePath: "/foo", rest nil}` | nil | nil | empty | **BLANK SHELL** | emptyState ✓ |
| `{linearID: "LEAF-1", rest nil}` | "LEAF-1" | nil | empty | taskLine | taskLine |
| `{branch: "foo", rest nil}` | nil | "foo" | empty | taskLine | taskLine |
| populated | "LEAF-1" | "foo" | non-empty | full render | unchanged |

No regression on populated states. Only the blank-shell case is fenced.

### 4.3 No new tests

Leaf precedent — view-layer unit tests not yet adopted (Track-9 §9.3 C-43 carry). Verification via build success + manual smoke step A (§6).

---

## 5. F3 — workspace path fallback when frontmost = Leaf.app

### 5.1 Moat change

`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Insights/ProdInsights+CurrentTaskIdentity.swift` — `currentWorkspacePath()` extended:

```
1. lastActivity → frontmost bundleID.
2. WorkspacePathResolver.resolve(bundleID:db:) → if non-nil, return.
3. resolveMostRecentIDEWorkspacePath() — distinct attention bundles
   in last 24h ordered by MAX(ts) DESC; first resolvable wins.
```

24h cap (`ideFallbackLookbackMs = 24 * 3600 * 1000`) matches the day-window semantic of `todayMetrics`. Longer-lookback workspace is likely stale (user moved on / weekend break). Non-IDE bundles short-circuit naturally — `WorkspacePathResolver.resolve` returns nil for browsers/Slack/Terminal/Leaf, so the loop walks past them. Path bytes stay in-memory only — D-8 preserved (TaskIdentity unchanged).

### 5.2 Tests

`ProdInsightsCurrentTaskIdentityTests.swift` extended with a `seedEvent` helper + 5 new tests:

- `testCurrentWorkspacePath_frontmostIDE_returnsResolvedPath` — frontmost Xcode, direct resolve.
- `testCurrentWorkspacePath_frontmostNonIDE_fallsBackToRecentIDE` — Leaf foreground, Xcode 30min ago → returns Xcode doc_path.
- `testCurrentWorkspacePath_frontmostNonIDE_noRecentIDE_returnsNil` — Leaf foreground, no IDE history → nil.
- `testCurrentWorkspacePath_fallback24hCap_skipsStaleIDE` — Leaf foreground, only IDE event 25h old → nil.
- `testCurrentWorkspacePath_multipleIDEs_picksMostRecent` — VSCode 5h ago + Xcode 30min ago + Leaf now → Xcode (most recent IDE).

### 5.3 Sentinel discipline

T2 sentinel test (`test_gitDeltaReader_StripsWorkspacePathAndFilenamesFromSnapshot`) covers the consumer surface and is unaffected by F3 — F3 widens the producer of the `workspacePath` argument but the consumer's output sanitization is the same. Carry §7: add a sentinel test for the new producer path (low priority — producer return value still flows through a consumer surface that is already proven to sanitize).

---

## 6. Verification — landed

All gates green on the implementation tip:

1. **5/5 Debug schemes** — LeafCore + LeafCorePrivate (`swift test` exit 0), Leaf + LeafAgent + LeafMCP (`xcodebuild build` SUCCEEDED).
2. **SPM tests** — full sweep exit 0. New tests: 4 fence (F1) + 5 fallback (F3) = 9 moat tests added; 0 public tests added.
3. **`just check-tokens`** — 3-tier clean (BASE+MIGRATION+RETIRED).
4. **Privacy walkback** — `grep -nE "absolute_path|file_contents|notes_body|email_subject|raw_prompt|tool_input|tool_response|note_body"` over the 3 touched files → 0 hits.
5. **Sentinel-injection EXEMPT** per §5.3.
6. **No new SQLCipher migrations** — empty diff under `Packages/LeafCore/Sources/LeafCore/DB/`.
7. **No new ShareEventTypeKey entries** — empty diff on `ShareEventTypeRegistry.swift`.
8. **No new public LeafCore surface** — only F2 view + spec markdown commits land publicly; F1/F3 moat is gitignored.
9. **`InsightsReader.refresh()` pipeline call count** — unchanged at 24 (F3's nested fallback query is a sub-step of `currentWorkspacePath()`, not a new top-level pipeline call).

### Manual smoke (Dima driver, post-merge)

| # | Action | Expected |
|---|---|---|
| A | Foreground Leaf with `~/Desktop/Leaf/leaf` workspace open in Xcode | RESUME hero NOT blank; taskLine + anchor + WIP line + Diff CTA populated |
| B | Switch to Xcode, edit a file, return to Leaf | gitDelta refreshes within one refresh cycle |
| C | 5-min typical Cmd-Tab churn IDE↔Slack↔Browser, check TODAY switches | Counter 1-5 range; brief Slack visits don't count |
| D | Foreground Leaf 30s+ then check TODAY counter | No spike from Leaf-foreground micro-dwells |
| E | Open Leaf with no recent IDE in 24h | emptyState (no blank shell) |
| F | Reset to clean tree on `main` | WIP line hidden; Diff CTA hidden on main itself |

---

## 7. Out of scope (carries)

- **C-25 sleep/wake substrate bug** (master spec §9.1) — adjacent but blocks a different UX promise; own dedicated phase.
- **Q1 sustained-state machine** — alternative switches algorithm that handles return-to-base correctly; revisit if telemetry shows over-count.
- **`contextSwitchMinHoldMs` user-tunable** — defer until users report mismatch with their workday rhythm. 60s ships hardcoded.
- **MRU IDE workspace cache TTL** — cheap query (24h, GROUP BY), defer optimization until profiling shows hot path.
- **View-layer unit tests for ResumeHeroBlock** — framework-adoption carry (Track-9 §9.3 C-43).
- **F1 SQL `ORDER BY ts, id` tie-break** — when batch flushes write identical `ts`, window ordering is impl-defined. Telemetry trigger.
- **F3 `EXPLAIN QUERY PLAN` profiling** — verify the 24h GROUP BY plan; add composite index if hot.
- **Per-IDE-family `currentWorkspacePath` precedence override** — Settings → Advanced primary-IDE preference. Telemetry trigger.
- **Sentinel-injection test for `currentWorkspacePath` fallback producer path** — current T2 sentinel test covers consumer; add a moat test that seeds sentinel-bearing fallback path.
- **Test-comment cleanup pass** — sweep adjacent assertions for stale comments after threshold semantic shift.

---

## 8. CTO review findings (Stage 4.5, 2 passes)

Two passes — initial pass surfaced HIGH/MEDIUM items; second pass (per explicit user-as-CTO request) caught a CRITICAL math error in my own first-pass "fix" to the fence-test seeds.

**Top-level scores:**

| Pass | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| First | 0 | 2 (FIXED) | 4 (3 RISK-ACCEPT, 1 DEFER) | 5 |
| Second | 1 (FIXED — own math error) | 0 | 2 (1 FIXED, 1 DEFER) | 1 (NO-OP) |

All CRITICAL/HIGH addressed inline; risk-accepts dispositioned with rationale; defers emit §7 carries. Highest-impact finding:

- **Critical (second-pass)** — first-pass §3.3 seed `A@0, B@30, A@200` with `expect=1` was arithmetically wrong: the gate measures destination dwell (time until next event), so B's dwell = 200 − 30 = 170s ≥ 60 → counted; A's open dwell also counts → actual 2, not 1. Test would have RED'd for the wrong reason; a sloppy implementer could have "fixed" by removing the gate. **FIXED INLINE** with `A@0, B@30_000, A@45_000` (B's dwell = 15s, rejects flicker; A's open dwell counts; total = 1). Per-row dwell walkthrough added to every fence test docstring as a future-CTO regression-prevention pattern.

Full first-pass findings table preserved in plan `~/.claude/plans/track-10-t2-5-typed-hoare.md` § "CTO review findings".

---

## 9. References

- Master spec: `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md`.
- T1 spec: `docs/superpowers/specs/2026-05-22-track-10-T1-foundation.md`.
- T2 spec: `docs/superpowers/specs/2026-05-22-track-10-T2-resume-hero.md`.
- T3 spec: `docs/superpowers/specs/2026-05-22-track-10-T3-younow-badge.md`.
- `.claude/shared/architecture.md` — substrate baseline (registry 198, 30 SQLCipher tables, 15 MCP tools — unchanged through T2.5).
- `.claude/shared/conventions.md` — 8-stage workflow.
- ADR-010 walkback discipline — T2 sentinel-injection lineage.
