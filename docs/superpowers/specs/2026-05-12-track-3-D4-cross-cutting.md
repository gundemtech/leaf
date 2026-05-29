# Track-3 D4 — Cross-cutting (Minimal)

**Date:** 2026-05-12
**Status:** Draft (brainstorm-approved by user, awaiting implementation plan in separate session)
**Owner:** Alex
**Branch (off):** `feature/track-3-D3-slack-deep-sweep` (tip `9bbe1cc`)
**Branch (new):** `feature/track-3-D4-cross-cutting`
**Contract:** `docs/superpowers/specs/2026-05-11-track-3-providers-deep-sweep-design.md` § "D4 — Cross-cutting" (lines 98-104)

## Goal

Close cross-cutting D2/D3 dispatcher gaps в `DetectorPipeline` + `EventLinksStore` body-kind dispatch tables. Replace remaining `hasPrefix("gh_pr_")` catch-alls с explicit case lists mirroring the FTS dispatcher (which D2 already fixed). Extend `DispatchCoverageTests` parity assertions so future drift across the three dispatchers is caught at CI.

D4 is the **last sub-phase of Track 3** before the collective acceptance gate. Track 3 stack — D1 (Linear deep sweep) → linear-reconciliation hotfix → D2 (GitHub deep sweep) → D3 (Slack deep sweep) → D4 (this) — merges collectively after manual smoke matrix passes per the track contract §13.

## Context

Discovery (2026-05-12, Stage 1 of phase-session workflow) found three dispatchers with **divergent body-kind dispatch tables**, despite D1/D2/D3 wiring claims:

| Dispatcher | File | D1 wired | D2 wired | D3 wired | hasPrefix("gh_pr_") catch-all |
|---|---|---|---|---|---|
| FTS (`EventsFullTextStore.topLevelBodyKind`) | `Packages/LeafCore/Sources/LeafCore/DB/EventsFullTextStore.swift:101` | ✅ | ✅ | ✅ | Already replaced (explicit cases lines 114-122) |
| Detector (`DetectorPipeline.topLevelBodyKind`) | `Packages/LeafCore/Sources/LeafCore/Detection/DetectorPipeline.swift:278` | ✅ (Linear notification intentionally excluded — see existing comment lines 281-283) | ❌ gist / release / deployment **MISSING** | ✅ | ❌ Still present (line 289) |
| EventLinks (`EventLinksStore.topLevelBodyKind`) | `Packages/LeafCore/Sources/LeafCore/DB/EventLinksStore.swift:205` | ✅ | ❌ gist / release / deployment **MISSING** | ❌ canvas / bookmark **MISSING** | ❌ Still present (line 216) |

**Downstream effects of gaps:**
- **Detector gap:** D2 gist descriptions / release bodies / deployment descriptions don't reach `DecisionDetector` / `OpenQuestionDetector` / `BlockerPatternDetector`. Outcome-bearing bodies invisible to Track-1 D3 detection layer.
- **EventLinks gap:** D2 + D3 bodies don't reach `LinearIDExtractor` cross-provider linker. "LEAF-123" reference in a gist description / release body / deployment notes / Slack canvas title / bookmark title creates zero `event_links` rows. Direct loss for Track-1 D2 cross-source association graph.
- **`hasPrefix("gh_pr_")` risk:** Any future `gh_pr_*` event_kind без body (e.g. `gh_pr_review_thread_resolved`, `gh_pr_awaiting_review_count` — both already shipped in D2) would be spuriously dispatched к `Schema.BodyKinds.ghPR`, leading to attempted body indexing on empty fields. FTS fixed this in D2 by switching к explicit list. Detector + EventLinks didn't follow.

**Cross-cutting observation:** The three dispatchers are intentionally duplicated (per current-state.md known carry-over: "Body-dispatch logic дублирована 3 раза — extract BodyExtractor walker before adding 4-го caller"). Refactoring to a shared helper is premature abstraction per CLAUDE.md root rule («Three similar lines is better than a premature abstraction»). Minimal D4 closes parity through explicit additions + a parity test fence, not through extraction.

## Scope

### In scope

1. **DetectorPipeline.topLevelBodyKind** — add D2 arms (gist / release / deployment) + replace `hasPrefix("gh_pr_")` (line 289) с explicit cases mirroring FTS lines 114-118 (`prOpened` / `prMerged` / `prClosed` → `.ghPR`).

2. **EventLinksStore.topLevelBodyKind** — add D2 arms (gist / release / deployment) + D3 arms (canvas + bookmark) + replace `hasPrefix("gh_pr_")` (line 216) с explicit cases.

3. **DispatchCoverageTests parity fence** — add `bodyKindForTesting(eventKind:) -> String?` public test accessors в DetectorPipeline + EventLinksStore (mirroring FTS line 156 pattern, returning `String?` raw value to keep DetectorPipeline's private `BodyKind` enum encapsulated). Add 4 new parity assertions: `GitHubEventKindKey.bodyBearing` → EventLinks parity (full mirror FTS), `GitHubEventKindKey.bodyBearing` → Detector parity (full mirror; Linear's notification exception is moot since GH enum has no notification case), `SlackEventKindKey.bodyBearing` → EventLinks parity (full mirror), `SlackEventKindKey.bodyBearing` → Detector parity (full mirror — currently passes since D3 wired Detector but defense-in-depth against future drift).

4. **Regression tests for hasPrefix replacement** — assert `gh_pr_review_thread_resolved` and `gh_pr_awaiting_review_count` return `nil` from both DetectorPipeline + EventLinksStore dispatchers (mirrors the implicit FTS behavior post-D2).

### Out of scope (deferred to other phases or hotfixes)

- **Share Controls UI build** — no `share_event_types` runtime persistence table yet (Phase 5+ work per registry comment line 7: «Runtime storage is Phase 5»). 116-entry registry exists, но UI build без persistence — premature. Defer.
- **Permissions sub-screen consolidation в Connections** — D2 GitHub `scopesSection` (line 599) + D3 Slack `slackScopesSection` (line 780) already cover granted-vs-missing + Re-authorize CTA + per-scope explainers. Consolidation into formal sub-screen is UX polish, не блокирует acceptance gate. Separate phase.
- **Reactions duplicate emission carry-forward** (D3 Task 27 review observation) — `SlackWarmCollector` lacks `priorReactionsRowPresent` gate + `reactionsDiff()` helper before iterating `batch.reactions.reactions`, leading to ~50 duplicate `slack_reaction_added` events per warm tick. Substrate-side fix, not D4 scope. Separate Linear ticket.
- **Cold bootstrap race carry-forward** (D3 Task 26 review I3) — `SlackColdScheduler` tick #1 fires before `SlackWarmScheduler` tick #1, so `topChannels` provider returns `.empty` and per-channel cold fan-out (canvases / channels_info / usergroups) skips. Acceptable per bootstrap discipline; verify via next 4am tick OR manual cursor reset. Separate hotfix if real workspaces show persistent gap.
- **BodyKindDispatcher refactor** — extracting a shared dispatcher to centralize the three places is premature abstraction (CLAUDE.md root rule). Parity fence catches drift without requiring the refactor. Defer until a 4th caller emerges.

## Architecture

### Dispatcher parity invariant

All three dispatchers (FTS / DetectorPipeline / EventLinksStore) MUST return the same `body_kind` for every body-bearing `event_kind`. Single intentional exception preserved:

- **`linear_notification_received` → DetectorPipeline returns nil** (existing comment `DetectorPipeline.swift:281-283`: «detectors only fire on outcome-bearing events; notifications are surface-only»). The other two dispatchers route it through `Schema.BodyKinds.linearNotificationTitle`. Since `linear_notification_received` isn't a member of `GitHubEventKindKey` or `SlackEventKindKey`, the parity assertions iterate only typed enums and the exception is handled by virtue of Linear notifications not appearing in either enum's `bodyBearing` set. No special-case logic in the parity tests.

### Body-kind catch-all safety

D2 fixed the FTS dispatcher's `hasPrefix("gh_pr_")` by replacing it with explicit `prOpened` / `prMerged` / `prClosed` cases. The same fix must land in DetectorPipeline + EventLinksStore. Going forward, any new body-bearing `gh_pr_*` event_kind MUST be added explicitly to all three dispatchers; any non-body-bearing `gh_pr_*` event_kind (like `gh_pr_review_thread_resolved` and `gh_pr_awaiting_review_count`) MUST NOT match any dispatcher arm. The parity fence enforces the former; explicit regression tests assert the latter.

### Drift prevention

Adding a new body-bearing event_kind to `GitHubEventKindKey.bodyBearing` or `SlackEventKindKey.bodyBearing` without updating all three dispatchers will fail `DispatchCoverageTests` on the parity assertion for whichever dispatcher is missing the arm. Tests block PR merge — drift cannot ship.

## File touches

| File | Change |
|---|---|
| `Packages/LeafCore/Sources/LeafCore/Detection/DetectorPipeline.swift` | Add `bodyKindForTesting(eventKind:) -> String?` public accessor returning `topLevelBodyKind(...).rawValue` (keeping `BodyKind` enum private). Extend `topLevelBodyKind` с D2 arms. Replace `hasPrefix("gh_pr_")` с explicit cases mirroring FTS. |
| `Packages/LeafCore/Sources/LeafCore/DB/EventLinksStore.swift` | Add `bodyKindForTesting(eventKind:) -> String?` public accessor. Extend `topLevelBodyKind` с D2 + D3 arms. Replace `hasPrefix("gh_pr_")` с explicit cases. |
| `Packages/LeafCore/Tests/LeafCoreTests/DispatchCoverageTests.swift` | +4 parity assertions (GH→Detector, GH→EventLinks, Slack→Detector, Slack→EventLinks). 8 → 12 assertions. |
| `Packages/LeafCore/Tests/LeafCoreTests/DetectorPipelineTests.swift` (or sibling test file) | +regression test: `gh_pr_review_thread_resolved` and `gh_pr_awaiting_review_count` return nil from DetectorPipeline dispatcher. |
| `Packages/LeafCore/Tests/LeafCoreTests/EventLinksStoreTests.swift` (or sibling test file) | +regression test: same two event_kinds return nil from EventLinksStore dispatcher. |
| `.claude/shared/current-state.md` | Closing note for D4 + Track 3 stack status. |

No schema migration. No new tables. No new payload keys. No new event_kinds. No new `ShareEventTypeKey` entries. No moat changes. No `LeafCorePrivate` changes.

## Test strategy

TDD sequential per CLAUDE.md «conventions.md → Одна phase = одна сессия» (Stage 5). Each step:
1. Write failing test
2. Run — confirm it fails
3. Implement minimal change
4. Run — confirm it passes
5. Run full suite — confirm baseline holds
6. Commit

### Step-by-step

| Step | Test added | Implementation | Commit message |
|---|---|---|---|
| 1 | EventLinksStore `bodyKindForTesting` accessor (or use existing pattern) + GH bodyBearing → EventLinks parity assertion (fails: gist/release/deployment missing) | Add 3 D2 arms in `EventLinksStore.topLevelBodyKind` (lines 207 area) mirroring FTS lines 126-135 | `feat(linker): EventLinksStore body-kind dispatcher D2 parity` |
| 2 | Slack bodyBearing → EventLinks parity assertion (fails: canvas + bookmark missing) | Add 2 D3 arm pairs in `EventLinksStore.topLevelBodyKind` mirroring FTS lines 139-149 | `feat(linker): EventLinksStore body-kind dispatcher D3 parity` |
| 3 | Regression test: `gh_pr_review_thread_resolved` + `gh_pr_awaiting_review_count` return nil from EventLinksStore | Replace `hasPrefix("gh_pr_")` (line 216) с explicit `prOpened` / `prMerged` / `prClosed` cases mirroring FTS lines 114-118 | `fix(linker): EventLinksStore explicit gh_pr_* cases vs hasPrefix catch-all` |
| 4 | DetectorPipeline `bodyKindForTesting` accessor + GH bodyBearing → Detector parity assertion (fails: gist/release/deployment missing) | Add 3 D2 arms in `DetectorPipeline.topLevelBodyKind` (around line 285 area) mirroring FTS | `feat(detection): DetectorPipeline body-kind dispatcher D2 parity` |
| 5 | Slack bodyBearing → Detector parity assertion (passes immediately — D3 already wired) | No implementation change — defense-in-depth fence assertion | `test(detection): DetectorPipeline Slack body-kind parity fence` |
| 6 | DetectorPipeline regression test: same two `gh_pr_*` event_kinds return nil | Replace `hasPrefix("gh_pr_")` (line 289) с explicit cases | `fix(detection): DetectorPipeline explicit gh_pr_* cases vs hasPrefix catch-all` |
| 7 | (no new test) | `.claude/shared/current-state.md` closing note for D4 + Track 3 stack status | `docs(shared): Phase Track-3 D4 landed — current-state update` |

After every step: all SPM tests pass + xcodebuild green + `just check-tokens` green. 7 atomic commits.

### Test count delta

| | Count |
|---|---|
| Baseline (D3 post-review + smoke tip `9bbe1cc`) | 1684 |
| +Parity assertions | +4 |
| +Regression tests (hasPrefix replacements) | +2 |
| +Possible dispatcher arm tests (if needed for TDD discipline) | +2 |
| **Target** | **~1692** |

Spec acceptance tolerance: ±5 tests. Higher only if TDD discipline surfaces unexpected coverage gaps.

## Acceptance criteria

- **AC1:** All 1684 baseline tests pass; ~1692 total after D4.
- **AC2:** 5/5 xcodebuild schemes green (Leaf / LeafAgent / LeafCore / LeafCorePrivate / LeafMCP).
- **AC3:** `just check-tokens` PASS + `just check-tokens-self-test` PASS.
- **AC4:** `DispatchCoverageTests` has 12 assertions (8 baseline + 4 parity).
- **AC5:** `grep -n 'hasPrefix("gh_pr_")' Packages/LeafCore/Sources/LeafCore/Detection/DetectorPipeline.swift Packages/LeafCore/Sources/LeafCore/DB/EventLinksStore.swift` returns zero results.
- **AC6:** `bodyKindForTesting` public accessor exists in both DetectorPipeline + EventLinksStore mirroring FTS pattern (line 156).
- **AC7:** No new event_kinds, no new payload keys, no new tables, no schema migrations, no `ShareEventTypeKey` registry changes.
- **AC8:** All D2 + D3 body-bearing event_kinds reach all three dispatchers (FTS / Detector / EventLinks) with single intentional exception of `linear_notification_received` → DetectorPipeline returns nil.

## Risks

- **R1 (low):** Public `bodyKindForTesting` accessor в DetectorPipeline exposes internal dispatch logic surface. Mitigation: accessor returns `String?` (raw value of private `BodyKind` enum, не enum value itself), so enum stays encapsulated and accessor is test-only by naming convention (mirrors FTS line 156).
- **R2 (low):** Parity tests catch drift but don't prevent it — defense-in-depth, not enforcement. Acceptable: mirrors existing DispatchCoverageTests pattern; test failure blocks PR merge, so practically equivalent to enforcement.
- **R3 (very low):** `hasPrefix("gh_pr_")` replacement might miss future PR event_kinds that should map to `.ghPR`. Mitigation: parity assertions catch this — any new `bodyBearing` PR event_kind will fail the parity test until added explicitly. Plus the contract already documents the invariant in spec language (see «Body-kind catch-all safety» section above).

## Dependencies

- Track-1 D2 substrate (FTS + event_links) — landed ✅
- Track-1 D3 substrate (DetectorPipeline + DetectorMoat) — landed ✅
- Track-3 D1 (Linear deep sweep + linear_notification_received body_kind) — landed ✅
- Track-3 D2 (GitHub deep sweep + gist/release/deployment body_kinds + FTS hasPrefix replacement) — landed ✅
- Track-3 D3 (Slack deep sweep + canvas/bookmark body_kinds + FTS canvas/bookmark dispatcher) — landed ✅

No new dependencies. D4 is purely substrate parity work on top of D1-D3.

## Open questions

None — Stage 2 brainstorm resolved all design questions. User signed off on Minimal scope (dispatcher parity + parity fence; UI work + carry-forwards deferred).

## Workflow per CLAUDE.md «Одна phase = одна сессия»

Eight stages, sequential, no parallelization inside Stage 5 implementation. Plan written in separate session per user direction («пиши спек сохраняй и потом в другой сессии будем план делать»).

1. ✅ Discovery (Stage 1)
2. ✅ Brainstorm (Stage 2)
3. ✅ Spec write (Stage 3) — **this document**
4. ⏭ Plan (Stage 4) — **separate session**, will invoke `superpowers:writing-plans` skill
5. ⏭ Implementation (Stage 5) — TDD sequential per plan
6. ⏭ Independent review (Stage 6) — `superpowers:code-reviewer` subagent
7. ⏭ Verification (Stage 7) — `superpowers:verification-before-completion`
8. ⏭ Ship (Stage 8) — final commit `docs(shared): Phase Track-3 D4 landed — current-state update`. **NO push, NO merge** — Track 3 stack waits collective merge after acceptance gate per contract §13.

## Post-D4 path

D4 closes Track 3 substrate work. After ship:

1. **Track 3 acceptance gate** — manual smoke matrix per contract §13:
   - **D1 smoke** на real Linear (comment reaction → `linear_comment_reaction_added`, @-mention → `linear_notification_received`, cycle start → `linear_cycle_started`, 4am cold → roadmap heartbeats + 4 snapshots)
   - **D2 smoke** на real GitHub (star repo → `gh_repo_starred`, scope revoke → banner, re-authorize → cleared)
   - **D3 smoke** на real Slack — **already done** per current-state.md (2026-05-12 alpha.11 + 22-scope re-auth + 4-tick smoke validation)
   - **D4 smoke:** FTS query hits на canvas/notification titles surface results; cross-provider linker creates `event_links` rows for LEAF-NN references found в gist descriptions / release bodies / Slack canvas titles
2. **Collective merge** D1 + linear-reconciliation + D2 + D3 + D4 в `main` (single coordinated merge per contract §13)
3. **Whitepaper sync** (separate session) — public-safe architectural framing only; implementation moat (GraphQL fragments, HTTP endpoint shapes, dispatcher internals) NOT published per pre-push-leaf checklist

D4 itself is small, but its merge unlocks the largest Track 3 step: collective merge of the full provider deep sweep (D1 + D2 + D3 + reconciliation + D4) от alpha.11 baseline (8 + 14 + 21 = 43 event_kinds) к Track 3 ship (27 + 32 + 52 = 111 event_kinds).
