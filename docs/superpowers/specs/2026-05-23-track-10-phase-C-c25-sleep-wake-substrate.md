# Track-10 Phase C — C-25 sleep/wake substrate idle gap

**Linear:** GUN-C (placeholder)
**Status:** IN PROGRESS — Stage 3 spec landing.
**Parent:** Track-9 master spec §9.1.C-25 (post-T7 discovery 2026-05-21) + Track-10 master spec §9.2 carry list.
**Branch:** `feature/GUN-C-track-10-c25-sleep-wake-substrate` off `feature/track-10-operational-home` tip `5b73b004` (Phase B SHIPPED).
**Date:** 2026-05-23.

---

## 1. Scope

Closes **C-25** (WhereStoppedDeriver sleep/wake idle gap) — the substrate bug that leaves WHERE STOPPED card stuck on empty-state copy in the dominant closed-laptop scenario. Currently observable in Track-10 T9 master smoke screenshots: `17h 30m focused so far` on YOU'RE ON is a related symptom (session start anchored to today midnight because Agent didn't capture a real idle window).

After Phase C SHIPPED → Track-10's last own-substrate carry resolved. Remaining open carries are all v1.1 / future / informational.

### 1.1 Root cause

`ProdWhereStoppedDeriver.derive()` (Track-1 D3 moat) computes latest activity ts via `MAX(ts) FROM events` with no signal-type filter. When the laptop sleeps and wakes:

- t=0 `system_slept` event emitted → Agent suspends
- t=30min `system_woke` event emitted on wake → most-recent event ts ≈ now
- t=30min+ε DetectorScheduler ticks → elapsed-since-latest-event ≈ 0 → idle gate `untilMs - latestTs >= idleSeconds * 1000` FAILS → no snapshot

The wake event itself overwrites the user's last real action as "latest event", masking the idle window.

### 1.2 Fix direction (Phase C decision)

**Direction 1** from master spec §9.1.C-25 — filter system-edge events from the latest-event read so the idle gate reflects actual activity elapsed-time, not the wake-event noise.

Excluded `event_kind` set (context-edge markers):
- `system_slept` (sleep started)
- `system_woke` (wake)
- `system_locked` (screen locked)
- `system_unlocked` (screen unlocked)

NOT excluded:
- `meeting_state_entered` / `_exited` (user joined / left a meeting — real activity)
- `focus_mode_enabled` / `_disabled` (user toggled focus — real activity)
- Any `attention` / `content` / `action` / `aiCollaboration` event

### 1.3 In-scope

1. Moat `ProdWhereStoppedDeriver.derive()` — augment `SELECT MAX(ts)` SQL with `WHERE` clause excluding 4 system-edge `event_kind` values via `NOT (signal_type = 'context' AND event_kind IN (...))`.
2. Sentinel-injection regression test (moat-side, gitignored) — verify deriver emits a snapshot in the closed-laptop scenario (sleep → wake gap > idle threshold → snapshot fires using pre-sleep activity as anchor).
3. Master spec §9.2 + Track-9 master spec §9.1.C-25 — mark RESOLVED Phase C.
4. `current-state.md` — Phase C SHIPPED.

### 1.4 Out of scope

- Direction 2 (emit synthesis snapshot on wake itself) — additional detector code path, not needed given Direction 1 closes the gap cleanly.
- Direction 3 (hybrid) — superset of Direction 1, unnecessary complexity.
- Symptom on YOU'RE ON `17h 30m focused so far` — this is a related symptom but lives in `ProdInsights+CurrentTaskSession.swift` (Phase B). Direction 1 fix on WHERE STOPPED is independent; YOU'RE ON dwell sum needs its own audit if user reports persistent inaccuracy (post-Phase-C smoke verifies).
- `meeting_state` / `focus_mode` event filter — keep counting as activity (real user-context changes).
- Sleep/wake handling for other detectors (`OpenQuestionDetector`, `BlockerPatternDetector`, etc.) — out of scope; their semantics differ.

---

## 2. Decisions

**D-C1.** **Direction 1 selected** (filter system-edge events from `MAX(ts)`). Simplest surgical change; minimal new code paths; preserves existing emit semantics. Direction 2 (emit-on-wake) adds a synthesis detector — unnecessary given Direction 1 suffices.

**D-C2.** **Excluded event_kind set**: `system_slept`, `system_woke`, `system_locked`, `system_unlocked`. Other context events (`meeting_state_*`, `focus_mode_*`) NOT excluded — they represent user activity transitions, not idle markers.

**D-C3.** **Sentinel-injection regression test (moat)** — seed events simulating closed-laptop scenario (real activity, then `system_slept`, then `system_woke` 30+ min later, then now), assert deriver emits a snapshot with the pre-sleep activity as anchor. Test sits in `Packages/LeafCore/Tests/LeafCorePrivateTests/Prod/Detection/ProdWhereStoppedDeriverTests.swift` (existing file).

**D-C4.** **Substrate-purity invariant held** — zero new event_kinds / migrations / MCP tools / public LeafCore additions. Moat-only SQL tweak + test.

**D-C5.** **Existing tests preserved** — verify existing `ProdWhereStoppedDeriverTests` still pass after SQL change. Filter only adds exclusion clause; doesn't alter happy-path semantics.

**D-C6.** **Atomic commit sequence ~5 commits**: spec landing · moat fix + tests · master spec markers · current-state.md · SHIPPED.

---

## 3. Implementation

### 3.1 Moat SQL change

`Packages/LeafCore/Sources/LeafCorePrivate/Prod/Detection/ProdWhereStoppedDeriver.swift`:

```swift
// Latest meaningful activity timestamp — excludes system-edge context
// events (sleep/wake/lock/unlock) so the idle gate reflects actual user
// activity elapsed-time, not the wake-event noise (C-25 Phase C, GUN-C
// 2026-05-23).
let latestEventTs: Int64? = try Int64.fetchOne(
    db,
    sql: """
            SELECT MAX(ts) FROM events
             WHERE NOT (
                signal_type = 'context'
                AND json_extract(payload_json, '$.event_kind') IN (
                    'system_slept', 'system_woke',
                    'system_locked', 'system_unlocked'
                )
             )
        """)
```

### 3.2 Sentinel-injection regression test (moat)

Add to `Packages/LeafCore/Tests/LeafCorePrivateTests/Prod/Detection/ProdWhereStoppedDeriverTests.swift`:

```swift
/// Phase C (GUN-C 2026-05-23) — closed-laptop scenario regression.
/// Seeds: real activity at T-2h, system_slept at T-90min, system_woke
/// at T-1min, then derive at now. Expects: snapshot emitted (idle gate
/// passes despite wake event being the literally-latest ts), anchor
/// reflects pre-sleep activity.
func test_derive_closedLaptopScenario_emitsSnapshot() throws { ... }

/// Phase C (GUN-C 2026-05-23) — system-edge filter scope.
/// Seeds: real activity at T-2h, system_locked at T-30min, derive at
/// now. Expects: snapshot emitted (lock events filtered too, not just
/// sleep/wake).
func test_derive_screenLockedScenario_emitsSnapshot() throws { ... }

/// Phase C (GUN-C 2026-05-23) — happy-path preservation.
/// Seeds: real activity at T-31min only (no system events). Expects:
/// existing happy-path behavior preserved — snapshot emitted.
func test_derive_awakeIdleScenario_stillEmitsSnapshot() throws { ... }
```

### 3.3 Verification

Phase C verification can't be smoke-tested in real-time (requires laptop sleep cycle). Sentinel tests cover the substrate-level assertion. Manual smoke deferred to Дима's next real closed-laptop cycle.

---

## 4. Acceptance gates

1. **AC-C1** — 5/5 xcodebuild Debug schemes BUILD SUCCEEDED.
2. **AC-C2** — SPM tests green: existing ProdWhereStoppedDeriverTests + 3 new Phase C tests pass. Pre-existing flake exception applies.
3. **AC-C3** — `just check-tokens` 3-tier clean.
4. **AC-C4** — Privacy walkback: 0 hits across Phase C scope (moat only).
5. **AC-C5** — Sentinel-injection tests green (T2 / T5 / T7 / Phase B / Phase C).
6. **AC-C6** — Substrate diff vs dev empty (DB / Registry / LeafMCP). Moat-only change.
7. **AC-C7** — Master spec §9.2 + Track-9 §9.1.C-25 marked RESOLVED Phase C.
8. **AC-C8** — Visual smoke deferred to Дима next closed-laptop cycle.

---

## 5. Carries after Phase C

| Carry | Status |
|---|---|
| C-25 (Track-9 §9.1) | RESOLVED Phase C |
| C-T10-EMIT-T7H1/H2/H3 | RESOLVED Phase B |
| C-T10-EMIT-T9-A11Y/HIG/A11Y-PRIMITIVES + T7-A11Y | RESOLVED Phase A |
| Phase 5.4 | OPEN — own track |
| LinearIDPrefixCache v1.1 | OPEN — multi-workspace trigger |
| C-T10-EMIT-STANDUP-HOURS | OPEN — v1.1 |
| C-T10-EMIT-MCP-STANDUP | OPEN — future |
| C-T10-EMIT-FLAKE | OPEN — test-infra triage |
| C-T10-EMIT-LOC-RESUMEHERO | OPEN — informational tracker |

**Track-10 closure status: 8 of 11 §9.2 + §9.1 carries RESOLVED through Phase A/B/C. Remaining 3 are v1.1 / future / informational — no own substrate phase blocked.**

---

## 6. Files touched

**Created:**
- `docs/superpowers/specs/2026-05-23-track-10-phase-C-c25-sleep-wake-substrate.md`

**Modified (public):**
- `docs/superpowers/specs/2026-05-22-track-10-operational-home-design.md` (§9.2 carry update note)
- `docs/superpowers/specs/2026-05-19-track-9-substrate-enrichment-design.md` (§9.1.C-25 RESOLVED marker)
- `.claude/shared/current-state.md` (Phase C landed)

**Modified (moat, gitignored):**
- `Packages/LeafCore/Sources/LeafCorePrivate/Prod/Detection/ProdWhereStoppedDeriver.swift`
- `Packages/LeafCore/Tests/LeafCorePrivateTests/Prod/Detection/ProdWhereStoppedDeriverTests.swift`

---

## 7. Workflow

1. ✅ Discovery — C-25 spec context in Track-9 master §9.1.C-25 + Track-10 §9.2; moat code read; SignalType enum + event_kind list verified.
2. ✅ Brainstorm — D-C1..D-C6; Direction 1 selected (filter system-edge events).
3. ✅ Spec write — this file.
4. ✅ Plan write — atomic commits per §3.
5. **NEXT**: Implementation — moat SQL + 3 sentinel tests.
6. **NEXT**: Verification — 8 AC gates.
7. **NEXT**: Ship — SHIPPED commit + FF merge to collective. Track-10 marathon complete.
