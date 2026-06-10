# Live tabs — real-time data refresh in Native UI

**Date:** 2026-06-10
**Status:** approved (design), pending implementation
**Scope:** MenuBarApp main window tabs. Priority: Home + Team.

## Problem

Today every tab loads its data once, on entry (`.onAppear` / `.task(id:)`). To see
anything new — fresh activity on Home, a new DM in the Team feed — the user has to
leave the tab and come back. The data itself is already fresh on disk:

- The Agent (separate process) writes events to the local encrypted DB continuously;
  the app never re-reads while a tab stays open.
- Team DMs/events arrive near-instantly (Realtime push + periodic polling fallback)
  and are upserted into local mirror tables **by the app process itself** — but
  `TeamFeedReader` only re-queries on tab entry. The unread badge updates; the feed
  does not.

## Goals

1. Home (and other local-insights tabs: Activity, Analytics) update **live** while
   visible — sub-second after the Agent commits a write.
2. Team feed updates **instantly** on incoming DM / team event (Realtime push) and
   on polling-tick catch-up.
3. Zero battery cost when the window is closed.
4. Minimal collision surface with the parallel `feature/account-login-phase1` work:
   **no edits to `RootView.swift`**, no composition-root restructuring.

## Non-goals

- Connections / Organization / Settings stay on-appear (config screens; roster
  already syncs via the existing periodic tick).
- No GRDB ValueObservation (it cannot observe writes from another process).
- No new network surface, no schema changes, no migrations.

## Design

### 1. `DatabaseChangeObserver` (new, LeafCore)

A small, self-contained type that watches the database files for cross-process
writes and emits a debounced "database changed" signal.

- **Mechanism:** `DispatchSource.makeFileSystemObjectSource` on `events.sqlite-wal`
  (`.write` / `.extend` events) plus the main `events.sqlite` (covers WAL checkpoint
  truncation). If the `-wal` file does not exist yet at start, watch the directory
  until it appears, then attach.
- **Debounce:** burst of file events → one signal after a short quiet window
  (default 500 ms, injectable for tests). Debounce logic is a pure, clock-injectable
  component — unit-tested in LeafCore without touching the filesystem.
- **Interface:** `start()` / `stop()`; emits via an injected `@Sendable () -> Void`
  callback. Fan-out to views goes through `LiveUpdateSignals` — a tiny `@MainActor
  @Observable` class with two monotonic counters (`localDataVersion` for
  agent-written insights data, `teamFeedVersion` for team-feed mirror changes).
  Views react with `.onChange(of:)` on the counter they care about; SwiftUI
  Observation is per-property, so Home churn never wakes the Team tab. (Chosen
  over `AsyncStream`: environment injection is type-keyed and streams are
  single-consumer; counters multicast for free.) No GRDB types in the interface;
  the observer knows only a file URL.
- **Concurrency isolation:** the DispatchSource runs on a private background queue.
  The observer itself is not MainActor-bound; consumers hop to `@MainActor`
  themselves (readers are `@Observable` MainActor types). No shared mutable state
  beyond the source handle, guarded by the queue.
- **Lifecycle:** owned by the window scene; started when the main window appears,
  stopped when it closes. Window closed ⇒ no file descriptors, no wakeups.

### 2. Home / Activity / Analytics — subscribe in the tab views

Each insights tab adds `.onChange(of: signals.localDataVersion)` (in the tab view
itself, **not** RootView) calling `InsightsReader.refresh()` (non-force). Tab not
visible ⇒ view doesn't exist ⇒ no redundant queries. The existing short freshness
guard in `InsightsReader` stays as a storm brake (non-force refreshes inside the
window are dropped; the agent's steady write stream re-triggers shortly after).

### 3. Team feed — in-process trigger, no watcher needed

New DMs and team events are written to the mirror tables by the app process
(`DirectMessageInboxReader.absorbRealtimePush`, `TeamEventMirrorReader.absorbRealtimePush`,
and the periodic polling ticks). Add an injectable `onMirrorChanged` closure on
both readers, fired after a successful mirror write: every successful realtime
absorb (INSERT and UPDATE — read receipts and done badges render in the feed),
polling ticks only when they actually upserted rows, and the optimistic local
mark-done update. The composition root wires both to
`signals.bumpTeamFeed()`; `TeamView` reacts via `.onChange(of:
signals.teamFeedVersion)` → `TeamFeedReader.refresh()` with the current workspace,
filters and self pubkey. Refresh merges state in place (existing `isRefreshing`
path) — scroll position is preserved; no full-screen loading flash.

Net effect: a colleague's message appears in the open feed at Realtime-push speed;
if Realtime is down, the polling tick catches up on its existing cadence.

### 4. Isolation & coordination with `feature/account-login-phase1`

- `RootView.swift` and `LeafApp.swift` composition order: untouched where possible;
  if a wiring line is unavoidable in `LeafApp`, it is additive-only (new property,
  no reordering).
- All new subscription code lives in tab views (`HomeView`, `ActivityView`,
  `AnalyticsView`, `TeamView`) and new LeafCore files.
- Branch `feature/live-tabs` off `dev`, kept small; merge order negotiated with the
  login branch (whichever lands second rebases — our diff is the cheaper rebase).

### 5. Error handling

- Watcher failure to attach (file missing, fd limit) → log via existing diagnostics,
  app degrades to today's behavior (on-appear refresh). Never fatal.
- Signal storm (e.g. WAL checkpoint rewrite) → absorbed by debounce + the reader's
  freshness guard.
- `refresh()` failures keep the existing per-reader error semantics (a failed
  refresh transitions to `.error` — pre-existing behavior, not changed by this
  work; the trigger source is irrelevant to the state machine).
- `InsightsReader` gains a warm-refresh path (from `.loaded`, keep the snapshot
  rendered during the re-query instead of flashing the loading scaffold) — without
  it every live refresh would blink the Home screen.

### 6. Testing

- **LeafCore unit (TDD):** `LiveUpdateSignals` counters; debounce component
  (burst → one signal; quiet → nothing); `DatabaseChangeObserver` against a temp
  dir (write → fires; stop → silent; wal created after start → attaches and fires).
- **App target:** no test bundle (known) — the `onMirrorChanged` firing conditions
  live in app-target readers and are trivial guards; build-verified
  (`xcodebuild -scheme Leaf`) + manual smoke.
- **Manual smoke (golden path):** (1) open Home, work in another app, watch Home
  update without re-entering; (2) open Team feed on Mac A, send DM from Mac B,
  watch it appear in the open feed; (3) close window, verify no file-watcher
  wakeups (Activity Monitor / fs_usage spot check).
