# M-XI — Staleness window for `InsightsReader.refresh()`

**Date:** 2026-05-23
**Branch:** `perf/m-xi-insights-staleness` (off `feature/invite-redesign`)
**Contract:** `.claude/plans/optimization-tier-m.md` row M-XI (Sev M, perf/UX)
**Workflow:** 8-stage "Одна phase = одна сессия" (`conventions.md`)

## Problem

`InsightsReader.refresh()` (`Leaf/Models/InsightsReader.swift:59-218`) runs ~16 sequential
SQL reads (`timeInApp`, `focusSessions`, `contextSwitchRate`, trends, AI breakdown, files,
Linear/GitHub/Slack activity, uninterrupted window, recent activity, recent sessions,
presence) on every call. It has a `currentTask?.cancel()` race guard but **no staleness
window**: every consumer's `.onAppear` / `.task` re-runs the full query set unconditionally.

The Native UI shell switches the same `InsightsReader` between tabs. Each tab change fires a
fresh ambient refresh:

- `RootView.swift:64` — `.onAppear { reader.refresh() }` (window/shell appear)
- `HomeView.swift:130` — `.onAppear`
- `ActivityView.swift:27` — `.onAppear`
- `MenuBarContent.swift:51` — `.onAppear` (popover open)
- `NotificationsSettingsSection.swift:68` — `.onAppear`
- `ShareControlsSettingsSection.swift:35` — `.task(id: activeWorkspaceID)`
- `ActiveTokensSection.swift:41` — `.task(id: activeWorkspaceID)`

Navigating Home → Activity → Profile → Settings re-runs ~100ms of SQL each hop even when the
previous successful load was seconds ago — a redundant refresh storm and a UI hitch under
@Observable invalidation churn.

## Fix

Mirror the established staleness idiom already in `LinearTeamsReader.swift:49-75`
(`lastFetchedAt: Date?` + injectable `ttl` + injectable `clock` + `refreshIfStale()`):
skip an ambient refresh when a successful load landed less than a `freshnessWindow` ago,
while always honoring user-initiated refreshes via a `force` flag.

### 1. New testable helper (LeafCore)

The app target (`Leaf`) has **no test target** — only LeafCore carries SPM tests. So the
freshness arithmetic (the only non-trivial logic) is extracted into a pure, unit-testable
LeafCore type:

```swift
// Packages/LeafCore/Sources/LeafCore/State/RefreshFreshness.swift
public enum RefreshFreshness {
  /// A result captured at `lastRefreshedAt` is fresh iff it lies strictly within
  /// `window` of `now`. A nil timestamp (no prior successful load) is never fresh,
  /// so the first refresh always proceeds.
  public static func isFresh(lastRefreshedAt: Date?, now: Date, window: TimeInterval) -> Bool {
    guard let lastRefreshedAt else { return false }
    return now.timeIntervalSince(lastRefreshedAt) < window
  }
}
```

Boundary semantics: `now - lastRefreshedAt == window` is **not** fresh (strict `<`), so a
refresh exactly at the window edge proceeds. `window == 0` ⇒ never fresh ⇒ never throttled.

### 2. `InsightsReader` changes (app target)

- Two new injected deps, defaults mirroring `LinearTeamsReader`:
  - `freshnessWindow: TimeInterval = 5`
  - `clock: @Sendable () -> Date = { Date() }`
- New `private var lastRefreshedAt: Date?` (MainActor-isolated; written on the MainActor
  in the completion handler).
- `refresh()` → `refresh(force: Bool = false)`. Gate at the **very top**, before
  `currentTask?.cancel()` and before the file-existence pre-check, so a fresh-enough state
  short-circuits without cancelling the (already-completed) task or re-stat'ing the file:

  ```swift
  func refresh(force: Bool = false) {
    // Staleness window — skip redundant SQL on rapid ambient tab switches.
    // Explicit user-initiated refreshes pass force:true and always proceed.
    if !force, RefreshFreshness.isFresh(lastRefreshedAt: lastRefreshedAt, now: clock(), window: freshnessWindow) {
      return
    }
    currentTask?.cancel()
    // … existing body unchanged …
  }
  ```

- Stamp `self.lastRefreshedAt = clock()` on **successful** completion — in **both** the
  `.loaded` and `.empty` branches (a query run that completed, with or without data). Do
  **not** stamp on `.error` (keeps transient failures retryable on the next ambient hop) and
  **not** on `.notConfigured` (no query ran; the cheap `fileExists` re-check stays so newly
  enabled collection is picked up promptly).

### 3. Call-site routing

| Call site | Trigger | Routing |
|---|---|---|
| `RootView.swift:64` | `.onAppear` | ambient — `refresh()` (unchanged) |
| `MenuBarContent.swift:51` | `.onAppear` | ambient — `refresh()` (unchanged) |
| `HomeView.swift:130` | `.onAppear` | ambient — `refresh()` (unchanged) |
| `ActivityView.swift:27` | `.onAppear` | ambient — `refresh()` (unchanged) |
| `NotificationsSettingsSection.swift:68` | `.onAppear` | ambient — `refresh()` (unchanged) |
| `ShareControlsSettingsSection.swift:35` | `.task(id:)` | ambient — `refresh()` (unchanged) |
| `ActiveTokensSection.swift:41` | `.task(id:)` | ambient — `refresh()` (unchanged) |
| `HomeView.swift:222` | "Try again" CTA | explicit — `refresh(force: true)` |
| `ActivityView.swift:69` | "Try again" CTA | explicit — `refresh(force: true)` |
| `ProfileView.swift:87` | "Try again" CTA | explicit — `refresh(force: true)` |
| `GenerateInviteSheet.swift:226` | "Done" button | explicit — `refresh(force: true)` |

The "Try again" banners render only from `.error` / `.empty` states; routing them through
`force:true` guarantees an explicit retry is never silently throttled even when a prior
success was within the window.

## Behavior after the change

- Rapid tab navigation within `freshnessWindow` of a successful load → ambient refreshes
  no-op, current `.loaded` snapshot stays on screen, zero SQL.
- First load, post-window ambient refresh, and every explicit CTA → full query set runs.
- After a failed refresh, ambient hops throttle for ≤ `freshnessWindow` against the last
  *success* timestamp (no error storm); the user-facing "Try again" forces through.

## Out of scope

- The other 11 Tier-M rows (own sessions).
- Reusing `RefreshFreshness` inside `LinearTeamsReader` (its inline `< ttl` already works) —
  noted as a future consolidation, not done here.
- Removing the vestigial `GenerateInviteSheet` "Done" → insights refresh (invite generation
  doesn't change today's activity); left as-is, now `force:true`.

## Testing

Pure-helper unit tests in LeafCore (`RefreshFreshnessTests.swift`), TDD-first:

1. `nil` timestamp ⇒ not fresh (refresh proceeds).
2. `now - last < window` ⇒ fresh (skip).
3. `now - last == window` ⇒ not fresh (boundary, strict `<`).
4. `now - last > window` ⇒ not fresh.
5. `window == 0` ⇒ never fresh regardless of timestamp.
6. negative delta (clock went backwards / `now` before `last`) ⇒ fresh (delta < window).

`InsightsReader` wiring (state matching, `force`, stamp placement, `clock` injection) is glue
verified by build green + manual smoke — the app target has no unit-test harness.

## Acceptance gate (manual smoke)

- **G1 throttle:** open app, let Home load → rapidly switch Home/Activity/Profile/Settings
  within ~5s → only the first hop runs SQL (verify via Console.app `tech.gundem.leaf.app`
  `insights` logs / no repeated query latency). After ~5s a hop runs again.
- **G2 explicit honored:** force an `.error`/`.empty` state → "Try again" runs immediately
  (not throttled), even right after a recent success.
- **G3 cold path:** no `events.sqlite` → `.notConfigured` persists, tab switches keep
  re-checking (enabling collection then switching tabs picks up data).

## Verification checklist

- Build green: `xcodebuild -scheme Leaf -configuration Debug build` (5/5 schemes).
- LeafCore SPM tests: `swift test --package-path Packages/LeafCore` (baseline 2155 from S8;
  +6 new `RefreshFreshness` tests).
- Independent `superpowers:code-reviewer` subagent against spec + plan before merge.
- `/pre-push-leaf` before any push to the public repo.
