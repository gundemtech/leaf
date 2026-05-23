# M-IV — `WorkspaceReader` off-main concurrency refactor

**Date:** 2026-05-23
**Branch:** `feature/invite-redesign` (atomic commits, same base as Tier S / other Tier-M fixes)
**Contract row:** `.claude/plans/optimization-tier-m.md` → M-IV (H/perf)
**Files:** `Leaf/Models/WorkspaceReader.swift` (`refresh` 84-129, `switchActive` 267-270, `leaveWorkspace` 291-327, `delete` 407-460, `hardDelete` 479-504), `Packages/LeafCore/Sources/LeafCore/State/ActiveWorkspaceStore.swift`, new pure resolver in `LeafCore`.

---

## 1. Problem

`WorkspaceReader` is `@MainActor @Observable`. `refresh()` and the mutating methods do their SQLCipher opens/reads/writes + identity-disk read + crypto **synchronously on the main thread**:

- `refresh()` (84-129): `ensureDatabase()` (SQLCipher KDF on first open) → `listWorkspaces` → `backfillIfNeeded` → `readTeamMembers` → `IdentityService.ensureLocalIdentity` (disk) → pubkey hex derive.
- `leaveWorkspace` (291-327): guard `readTeamMembers` + identity + `markLeft` (write) + `listWorkspaces` re-resolve + `refresh()`.
- `delete` (407-460) / `hardDelete` (479-504): local `softDelete`/post-cascade `listWorkspaces` on main (server PATCH / `cascadeDeleter.execute` are already off-main).

**Symptom:** every sidebar workspace switch (`switchActive → refresh`) and cold launch hitches main 100-500ms; under WAL contention with the Agent writer up to a multi-second freeze + beachball.

## 2. Goal & non-goals

**Goal:** move all blocking DB/crypto/disk work in `refresh` + the three mutating methods off the main thread, mutating `@Observable state` only on the MainActor, while keeping every public signature and all observable error/state semantics identical.

**Non-goals (explicitly out of scope):**
- DB connection-pool consolidation (M-VII).
- Coalescing for *other* readers — `JoinRequestsReader` / `InviteTokensReader` (M-VI). M-IV only coalesces `WorkspaceReader.refresh()`, the race it itself introduces.
- Normalizing the pre-existing signature inconsistency (`leaveWorkspace` sync-void surfacing via `state` vs `delete`/`hardDelete` `async -> String?`). Preserved as-is.
- Any UI-layer change. All 14 `refresh()` call sites + the `switchActive`/`leaveWorkspace`/`delete`/`hardDelete` call sites stay byte-for-byte unchanged.

## 3. Decisions (from brainstorm, all confirmed)

1. **`refresh()` stays sync** with the off-main work wrapped internally (mirrors `InsightsReader:80-86`). Zero call-site churn. The contract's "convert to async" wording was a sketch; intent (don't block main) is met without changing the public API.
2. **Cancel-prior coalescing**, bundled into M-IV: a stored `currentTask: Task<Void, Never>?`; each `refresh()` does `currentTask?.cancel(); currentTask = Task { … }`. Superseded refreshes bail at a cancellation check before any state write.
3. **Mutating methods get the same off-main treatment**, but their destructive writes run to completion on their **own** tasks (NOT `currentTask`, NOT cancel-prior) — cancelling a leave/delete mid-write would corrupt state.
4. **Preserve-stale during the async window** — `refresh()` never overwrites an existing `.loaded`/`.empty`/`.error` with `.loading`. Cold-start still shows `.loading` (the property already is). No `ProgressView` flash on warm sidebar switch / tab `.onAppear`.

## 4. Hard constraint that shapes the structure

`ActiveWorkspaceStore` is `@MainActor @Observable`. Therefore `activeWorkspaceID`, `setActive`, and `backfillIfNeeded` **cannot be called inside a `Task.detached` block** (compile error + would mutate `@Observable` state off-main). Consequence:

- All `activeStore` interaction stays on the MainActor: read the current id **before** the hop; conditionally `setActive` **after** the hop.
- The active-workspace **resolution logic** (which `backfillIfNeeded` and `refresh` rely on) must move into a pure, `nonisolated`, off-main-callable function.

## 5. Design

### 5.1 Pure resolver (new, in `LeafCore`) — the testable seam

```swift
// LeafCore — pure, no I/O, nonisolated, Sendable in/out
public struct ActiveResolution: Sendable, Equatable {
  public let active: Workspace?      // nil ⇒ caller emits .error("Couldn't resolve active workspace.")
  public let backfilledID: String?   // non-nil ⇒ caller must call activeStore.setActive() on MainActor
}

public func resolveActiveWorkspace(
  _ workspaces: [Workspace], knownActiveID: String?
) -> ActiveResolution
```

Semantics **identical to today's inline logic** (84-101):
- `knownActiveID` set and present in `workspaces` → `active = that`, `backfilledID = nil`.
- `knownActiveID == nil` → pick oldest by `createdAt` ASC (the existing backfill rule) → `active = oldest`, `backfilledID = oldest?.id`.
- `knownActiveID` set but absent from `workspaces` → `active = nil`, `backfilledID = nil` (caller → `.error`, matching line 99).
- empty `workspaces` → `active = nil`, `backfilledID = nil` (caller treats empty list as `.empty` *before* calling the resolver, per line 88).

`ActiveWorkspaceStore.backfillIfNeeded` is refactored to delegate to this resolver (single source of truth — in-scope, since this is the exact logic M-IV must relocate; not unrelated cleanup).

### 5.2 `refresh()` — sync, cancel-prior, single detached hop, preserve-stale

**`currentTask` is itself the detached task** (not an outer `@MainActor` task wrapping an inner detached one). This matters: `Task.detached` does NOT inherit cancellation, so the only way `Task.checkCancellation()` inside `loadSnapshot` does anything is if the task we cancel IS the detached one. So `refresh()` reads its MainActor inputs synchronously (it runs on main), then spawns a single detached task that does the off-main work and hops back to apply state. Captures `[weak self]` (detached tasks shouldn't strongly retain the reader).

> **Swift 6 concurrency correction (as built).** The illustrative code blocks below show `await MainActor.run { guard let self … }`. Swift 6 strict concurrency rejects that — capturing the task-isolated `self` inside a main-actor closure trips *"sending 'self' risks causing data races."* The shipped code instead hops via **isolated `@MainActor` apply-methods called through `await self?.…`**, which crosses the boundary with only Sendable values: `applyRefreshedSnapshot(_:)` / `applyRefreshFailure(message:debug:)` for `refresh()`, and `applyLeaveOutcome(_:wasActive:)` / `applyLeaveFailure(message:debug:)` for `leaveWorkspace`. To map an error → message off-main, `userFacingMessage(for:)` gains a `nonisolated static` twin (a thin instance forwarder keeps existing MainActor callers unchanged); the detached `catch` computes the Sendable `String` before the hop. `delete`/`hardDelete` are `@MainActor async` awaiting a *self-less* detached task, so they apply inline (no captured-self closure, no race).

```swift
private var currentTask: Task<Void, Never>?

func refresh() {
  currentTask?.cancel()
  let cachedDB = self.database                        // read MainActor inputs synchronously
  let url = databaseURL, cfg = databaseConfig, enc = databaseEncryption
  let root = keystoreRoot
  let knownActiveID = activeStore.activeWorkspaceID

  currentTask = Task.detached(priority: .userInitiated) { [weak self] in
    do {
      let snap = try WorkspaceReader.loadSnapshot(            // off main; checkCancellation inside
        cachedDB: cachedDB, url: url, cfg: cfg, enc: enc, root: root, knownActiveID: knownActiveID)
      try Task.checkCancellation()                           // superseded → bail before applying
      await MainActor.run {
        guard let self else { return }
        self.database = snap.db                              // cache opened handle (MAIN)
        if let id = snap.backfilledID { self.activeStore.setActive(id) }   // store write (MAIN)
        self.state = snap.state                             // .empty / .loaded / .removedFromActiveWorkspace / .error
        if case .loaded(_, let active, _) = snap.state {
          self.ensureActiveWorkspaceSyncedToSupabase(workspace: active, createdByPubkey: snap.myPubHex)
        }
      }
    } catch is CancellationError {
      // superseded by a newer refresh() — drop result, preserve stale state
    } catch {
      await MainActor.run {
        guard let self else { return }
        self.logger.error("WorkspaceReader.refresh failed: \(String(describing: error), privacy: .public)")
        self.state = .error(message: self.userFacingMessage(for: error))
      }
    }
  }
}
```

`Snapshot` is a file-scope `Sendable` struct: `(db: Database, state: State, backfilledID: String?, myPubHex: String)`. `Database` is `@unchecked Sendable`; `Workspace`/`TeamMember` (held inside `State`) are `Sendable`; **`State` gets a `Sendable` conformance added** (`enum State: Equatable, Sendable`). `myPubHex` is populated only for `.loaded`/`.removedFromActiveWorkspace` (identity is loaded after a resolve success); for the `.empty`/`.error` early returns it is `""` and never read (supabase-sync is gated on `if case .loaded`).

`loadSnapshot` (`nonisolated private static` — the class is `@MainActor`, so the helper must be `nonisolated` to run off the main actor; runs off-main):
1. `let db = try cachedDB ?? Database.openForWrite(at: url, config: cfg, encryption: enc)` — **reuse cached write pool; never open a second connection.**
2. `let workspaces = try db.listWorkspaces(includeLeft: false)`; if empty → return `Snapshot(state: .empty, …)`.
3. `try Task.checkCancellation()`
4. `let resolution = resolveActiveWorkspace(workspaces, knownActiveID: knownActiveID)`; if `resolution.active == nil` → return `Snapshot(state: .error("Couldn't resolve active workspace."), …)` (preserves line 99 behavior).
5. `let allMembers = try db.readTeamMembers(workspaceID: active.id, includeRemoved: true)`
6. `try Task.checkCancellation()`
7. `let priv = try IdentityService.ensureLocalIdentity(at: root)`; derive `myPubHex`.
8. self-removed check (lines 108-113) → either `.removedFromActiveWorkspace` or `.loaded(workspaces, active, activeMembers)`.
9. return `Snapshot(db, state, resolution.backfilledID, myPubHex)`.

**No `state = .loading` anywhere** (preserve-stale). The detached task captures `[weak self]` and only Sendable locals; all `self` access (state, activeStore, logger) happens inside `MainActor.run`.

### 5.3 Mutating methods — own run-to-completion hops

`leaveWorkspace(workspaceID:)` (signature stays sync-void). A standalone detached task — **NOT** `currentTask`, and **not cancellable** (the destructive write must complete):

```swift
func leaveWorkspace(workspaceID: String) {
  let cachedDB = self.database, root = keystoreRoot
  let url = databaseURL, cfg = databaseConfig, enc = databaseEncryption
  let wasActive = (activeStore.activeWorkspaceID == workspaceID)   // ON MAIN
  Task.detached(priority: .userInitiated) { [weak self] in        // own task, never cancelled
    do {
      let outcome = try WorkspaceReader.performLeave(             // guard + markLeft + re-resolve OFF main
        cachedDB: cachedDB, url: url, cfg: cfg, enc: enc, root: root,
        workspaceID: workspaceID, wasActive: wasActive)
      await MainActor.run {
        guard let self else { return }
        self.database = outcome.db
        if wasActive { self.activeStore.setActive(outcome.remainingFirstID) }   // ON MAIN
        self.refresh()                                            // coalesced read path repopulates state
      }
    } catch {
      await MainActor.run {
        guard let self else { return }
        self.logger.error("WorkspaceReader.leaveWorkspace failed: \(String(describing: error), privacy: .public)")
        self.state = .error(message: self.userFacingMessage(for: error))
      }
    }
  }
}
```

`performLeave` (`nonisolated private static`, **no `checkCancellation` in the write path**): open db; solo-admin guard (`readTeamMembers(includeRemoved:false)` + identity + `count == 1 && me.role == .admin`) → throws `WorkspaceReaderError.soloAdminCannotLeave` (mapped in `userFacingMessage` to the existing string 307-309); else `WorkspaceService(database:keystoreRoot:).markLeft(workspaceID:at: Date())`; if `wasActive`, compute `remainingFirstID` via the shared `computeRemainingFirstID(db, excluding:)` helper (filter/sort/first, 315-319). Returns `MutationOutcome(db, remainingFirstID)`.

`delete(workspaceID:) async -> String?` — preserve **local-first ordering** (425-453): the local `softDelete` + conditional `remaining` re-resolve move into one awaited detached hop; on success cache db + `setActive` (if was active) on main + `refresh()`; then the existing best-effort `supabase.softDeleteWorkspace` PATCH (already off-main, unchanged, including the `.noRowsAffected` info-log branch). Error path returns `userFacingMessage` `String?` exactly as today.

`hardDelete(workspaceID:) async -> String?` — `cascadeDeleter.execute` is already an awaited actor hop (unchanged). The only main-blocking part — the post-cascade `listWorkspaces` re-resolve (487-494) — moves into a small awaited detached hop; cache db + `setActive` (if was active) on main + `refresh()`. The `cascadeDeleter == nil` guard (480-484) stays on main, unchanged.

`switchActive(to:)` is unchanged source (`activeStore.setActive(workspaceID); refresh()`) — it inherits the new async `refresh()` for free.

### 5.4 Helper placement

Off-main helpers are `nonisolated private static` functions on `WorkspaceReader` (capture nothing from `self`, take explicit Sendable params; `nonisolated` is required because the class is `@MainActor`):
- `openDB(cachedDB:url:cfg:enc:) throws -> Database` — DRY the `cachedDB ?? Database.openForWrite(...)` open.
- `computeRemainingFirstID(_ db:excluding:) throws -> String?` — DRY the `listWorkspaces(includeLeft:false).filter { $0.id != excluding }.sorted { … localizedCaseInsensitiveCompare … }.first?.id` re-resolve shared by leave/delete/hardDelete.
- `loadSnapshot(...) throws -> Snapshot` (refresh).
- `performLeave(...) throws -> MutationOutcome`, `performDelete(...) throws -> MutationOutcome` (leave/delete writes). `hardDelete`'s post-cascade re-resolve calls `openDB` + `computeRemainingFirstID` inline in its detached block (no dedicated helper).

`Snapshot` and `MutationOutcome { db: Database; remainingFirstID: String? }` are **file-scope** `Sendable` structs (declared outside the class to avoid any `@MainActor` isolation inference). `WorkspaceReaderError: Error { case soloAdminCannotLeave }` is also file-scope. The resolver + `ActiveResolution` are the only additions to `LeafCore`'s public surface.

## 6. Concurrency invariants (safety contract)

1. `activeStore` touched **only on MainActor** — read synchronously before each detached hop (in the `@MainActor` method body), conditional `setActive` inside `MainActor.run` after.
2. Detached closures capture `[weak self]` + **only Sendable values** (`Database` `@unchecked Sendable`; `WorkspaceService` `Sendable`; `IdentityService` stateless enum; resolver pure; `Workspace`/`TeamMember`/`State` `Sendable`). All `self` access (state/activeStore/logger/ensureSync) happens inside isolated `@MainActor` apply-methods invoked via `await self?.…` — never inside a captured-self `MainActor.run` closure (which Swift 6 rejects as a data race). Only Sendable values (the snapshot/outcome structs, `String` message+debug) cross the boundary.
3. **Cancellation is real for `refresh()`** — `currentTask` IS the detached task, so `currentTask?.cancel()` propagates to `Task.checkCancellation()` (after `loadSnapshot`) → `CancellationError` → caught and dropped, never reaching `MainActor.run`. Stale state preserved. Cancellation only skips a state write; it never rolls back a side effect (`refresh` does no DB write; `setActive` fires only on the winning task, on main).
4. **Destructive writes are uncancellable** — `leaveWorkspace`/`delete`/`hardDelete` spawn standalone detached tasks (never stored in `currentTask`, never cancelled) with no `checkCancellation` in the write path. `markLeft`/`softDelete`/`cascadeDeleter.execute` always run to completion.
5. **One DB connection** — `openDB` reuses the cached write pool (`cachedDB ?? openForWrite`); no parallel read pool.
6. **Error semantics unchanged** — each detached task `do/catch`es; `userFacingMessage(for:)` mapping + all `state`/`String?`-return transitions happen on MainActor; same strings, same branches. `WorkspaceReaderError.soloAdminCannotLeave` is added to `userFacingMessage`'s first branch.

## 7. Testing

**Unit (LeafCore, XCTest — matches `WorkspaceReaderOrchestrationTests`):** `resolveActiveWorkspace` — known-id-found / known-id-nil-picks-oldest-by-createdAt / known-id-absent→nil / empty-list / single-workspace. (The resolver receives an already-filtered list — `listWorkspaces(includeLeft: false)` — so left/deleted-row exclusion is the DB query's responsibility, exercised by the backfill characterization test, not the resolver tests.) Plus a characterization test that `backfillIfNeeded` (now delegating) behaves identically to its prior inline form.

**Async glue** (Task.detached hop, cancel-prior, MainActor mutation) lives in the app target with no test bundle — same constraint all existing `WorkspaceReader` glue lives under. Covered by **manual smoke**:
- Rapid sidebar A→B→C switch → no beachball, no spinner flash, lands on C's content.
- Cold launch → `.loading` shows once, then `.loaded`.
- `leaveWorkspace` (solo-admin guard error path + normal leave re-resolving active), `delete`, `hardDelete` → complete and re-resolve active correctly; UI never freezes.

**Gates:** `swift test --package-path Packages/LeafCore` green (≥2155 baseline + new tests); `xcodebuild` 5/5 schemes green; `/pre-push-leaf` before any push.

## 8. Acceptance criteria

- [ ] `refresh()` / `leaveWorkspace` / `delete` / `hardDelete` perform zero blocking SQLCipher/crypto/disk work on the main thread (all inside `Task.detached`).
- [ ] All public signatures unchanged; all call sites compile untouched.
- [ ] Cancel-prior on `refresh()`; destructive writes uncancellable.
- [ ] No `state = .loading` on warm refresh; cold-start unchanged.
- [ ] `activeStore` accessed only on MainActor.
- [ ] One DB connection (no new pool).
- [ ] New `resolveActiveWorkspace` unit-tested; `backfillIfNeeded` regression test green.
- [ ] 5/5 xcodebuild schemes green; LeafCore SPM suite green.
