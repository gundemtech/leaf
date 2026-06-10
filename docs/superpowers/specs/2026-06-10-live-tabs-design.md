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
- **Interface:** `start()` / `stop()`; consumers receive signals via an
  `AsyncStream<Void>` (fits the SwiftUI `.task` for-await loop directly). No GRDB
  types in the interface; the observer knows only a file URL.
- **Concurrency isolation:** the DispatchSource runs on a private background queue.
  The observer itself is not MainActor-bound; consumers hop to `@MainActor`
  themselves (readers are `@Observable` MainActor types). No shared mutable state
  beyond the source handle, guarded by the queue.
- **Lifecycle:** owned by the window scene; started when the main window appears,
  stopped when it closes. Window closed ⇒ no file descriptors, no wakeups.

### 2. Home / Activity / Analytics — subscribe in the tab views

Each insights tab adds a `.task` (in the tab view itself, **not** RootView) that
loops over the observer's stream while the tab is visible and calls
`InsightsReader.refresh(force:)` on each signal. Tab not visible ⇒ its `.task` is
cancelled by SwiftUI ⇒ no redundant queries. The existing short freshness guard in
`InsightsReader` stays as a storm brake.

### 3. Team feed — in-process trigger, no watcher needed

New DMs and team events are written to the mirror tables by the app process
(`DirectMessageInboxReader.absorbRealtimePush`, `TeamEventMirrorReader.absorbRealtimePush`,
and the periodic polling ticks). Add an injectable `onNewRows` notification
(closure) fired by those readers after a successful upsert of *new* rows; the Team
tab wires it to `TeamFeedReader.refresh()` with the current workspace, filters and
self pubkey. Refresh merges state in place (existing `isRefreshing` path) — scroll
position is preserved; no full-screen loading flash.

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
- `refresh(force:)` failures keep the existing per-reader error states; a failed
  live refresh must not blank a previously loaded screen (readers already keep last
  loaded snapshot — verify in tests).

### 6. Testing

- **LeafCore unit (TDD):** debounce component (burst → one signal; quiet → nothing;
  clock injected). Observer start/stop idempotence. `onNewRows` fired exactly when
  absorb/tick upserts new rows, not on no-op ticks.
- **App target:** no test bundle (known) — view wiring is build-verified
  (`xcodebuild -scheme Leaf`) + manual smoke.
- **Manual smoke (golden path):** (1) open Home, work in another app, watch Home
  update without re-entering; (2) open Team feed on Mac A, send DM from Mac B,
  watch it appear in the open feed; (3) close window, verify no file-watcher
  wakeups (Activity Monitor / fs_usage spot check).
