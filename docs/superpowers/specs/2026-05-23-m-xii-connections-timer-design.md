# M-XII — Scope `ConnectionsView` countdown timer to per-countdown leaf views

**Date:** 2026-05-23
**Branch:** `perf/m-xii-connections-timer` (off `feature/invite-redesign`)
**Contract:** `.claude/plans/optimization-tier-m.md` row M-XII (Sev L, perf/UX)
**Workflow:** 8-stage "Одна phase = одна сессия" (`conventions.md`)

## Problem

`ConnectionsView` drives a screen-wide 1Hz invalidation:

- `nowTick: Date` — `@State` (`ConnectionsView.swift:50`)
- `countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()` (`:51`)
- `.onReceive(countdownTimer) { nowTick = $0 }` (`:109-111`) rewrites the `@State` every second

A `@State` write invalidates the **entire** `ConnectionsView.body`: all three provider
sections (Linear / GitHub / Slack) and every `LeafCard.raised` re-render once per second,
producing steady 1Hz CPU on the Connections page.

The **only** consumer of `nowTick` is `countdownLabel(expiresAt:)` (`:540-548`), used in
exactly one place — `githubDeviceFlowBlock` (`:386`) — which renders only when
`githubOAuth.state == .awaitingAuthorization(...)` (the transient GitHub Device Flow
RFC 8628 step where the user enters a device code). So the screen-wide tick runs
continuously even though the countdown it feeds is almost never on screen.

## Fix

Mirror the established codebase pattern (`GenerateInviteSheet.swift:164`,
`ActiveTokensSection.swift:155`): a per-countdown `TimelineView` instead of a parent-level
`@State` timer.

1. **Delete** `nowTick` (`:50`), `countdownTimer` (`:51`), and the
   `.onReceive(countdownTimer) { … }` block (`:109-111`). Remove `import Combine`
   (`:15`) — it was present only for `Timer.publish`; confirm nothing else in the file
   needs it before removing.

2. **Refactor** `countdownLabel(expiresAt:)` → `countdownLabel(expiresAt:now:)`:
   a pure function taking the reference date as a parameter instead of reading the
   `nowTick` instance state. Formatting logic is otherwise **identical** (MM:SS,
   `max(0, …)` clamp, "Code expired — try again." at `remaining <= 0`). This matches
   the `(expiresAt:now:)` signature convention used by the two precedent helpers.

3. **Wrap** the countdown `Text` in `githubDeviceFlowBlock` (`:386`):

   ```swift
   TimelineView(.periodic(from: .now, by: 1)) { ctx in
     Text(countdownLabel(expiresAt: expiresAt, now: ctx.date))
       .font(LeafType.body.small)
       .foregroundStyle(LeafColor.text.tertiary)
   }
   ```

### Why this satisfies "stop publisher when no countdown active"

`TimelineView` exists in the view tree only while `githubContent` renders the
`.awaitingAuthorization` branch. No active device flow → no `TimelineView` → no timer.
And during an active device flow, the `TimelineView` re-render is scoped to its own
subtree (the single countdown `Text`), so the rest of the body no longer invalidates at
1Hz either.

## Scope boundaries

- **No behavior change** to the countdown text itself. Same format, same expiry copy.
  This is a pure relocation of *where* the per-second tick lives.
- **Not stopping the tick at code-expiry.** After `remaining <= 0` the `TimelineView`
  keeps ticking 1Hz but re-renders only the single "Code expired — try again." `Text`.
  This matches the `GenerateInviteSheet` precedent (which keeps ticking past "Expired")
  and the cost is negligible — one `Text` node, only while a user sits on an expired
  device-flow screen. Out of scope.
- **Not extracting the formatter to LeafCore.** Per session decision: match the two
  existing view-local precedents rather than expand LeafCore's public surface for a
  trivial MM:SS formatter. Keeps the diff to one file.
- **Not touching** the OAuth Connect button busy-state carry-over (separate row in
  the contract's cross-cutting section, bundled with M-VI).

## Testing strategy

The `Leaf/` app target has **no** unit-test target — all tests live in
`Packages/LeafCore/Tests`. The two precedent countdown helpers
(`GenerateInviteSheet.countdownText`, `ActiveTokensSection.countdownText`) are themselves
untested. Per session decision, this fix matches that precedent: verify via build +
SPM baseline + manual smoke rather than build new app-target test infrastructure or
extract to LeafCore for a zero-behavior-change refactor.

## Verification (per contract checklist)

- Build green: `xcodebuild -scheme Leaf -configuration Debug build` (5/5 schemes).
- LeafCore SPM tests: `swift test --package-path Packages/LeafCore` — baseline 2155,
  no delta expected (app-target view edit only).
- Independent code review subagent (`superpowers:code-reviewer`) against spec + plan.
- Manual smoke: trigger GitHub device flow → confirm "Code expires in M:SS" counts down
  once per second; confirm Linear/Slack cards no longer re-render every second when no
  device flow is active (e.g. instrument with a `let _ = Self._printChanges()` during
  dev, or visual: no per-second flicker). Golden path + expiry edge.
- `/pre-push-leaf` before any push to the public repo.

## Acceptance criteria

- AC1: `nowTick`, `countdownTimer`, and `.onReceive(countdownTimer)` removed from
  `ConnectionsView`.
- AC2: `countdownLabel` is pure (`expiresAt:now:`), no reference to instance timer state.
- AC3: GitHub device-flow countdown wrapped in `TimelineView(.periodic(from:.now, by:1))`
  and counts down once per second when `.awaitingAuthorization`.
- AC4: No `Timer.publish` remains in `ConnectionsView.swift`.
- AC5: 5/5 xcodebuild schemes build green; LeafCore SPM tests stay at baseline.
