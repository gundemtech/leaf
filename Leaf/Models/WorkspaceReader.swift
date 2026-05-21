//
//  WorkspaceReader.swift
//  Leaf
//
//  Phase Track-5 S2 — multi-workspace @Observable adapter (replaces OrgReader).
//  State machine spans no-workspaces → multi-workspace + active + members.
//  Subscribes to ActiveWorkspaceStore for active-workspace observation.
//  Self-removed detection per active workspace mirrors Phase 5.3.E.
//

import CryptoKit
import Foundation
import LeafCore
import OSLog
import Observation

#if LEAF_PROD
  import LeafCorePrivate
#endif

@MainActor
@Observable
final class WorkspaceReader {
  enum State: Equatable {
    case loading
    case empty  // no workspaces — onboarding
    case loaded(workspaces: [Workspace], active: Workspace, members: [TeamMember])
    case removedFromActiveWorkspace(workspaceName: String)
    case error(message: String)
  }

  private(set) var state: State = .loading

  private var database: LeafCore.Database?

  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?
  private let keystoreRoot: URL
  private let activeStore: ActiveWorkspaceStore
  /// Optional Supabase client used by rename() and delete() to PATCH the
  /// server before applying local mutations. Injected from LeafApp composition
  /// root (S7 Phase H). Nil during unit tests and early onboarding where
  /// Supabase may not yet be authenticated.
  private let supabase: SupabaseClient?
  /// Track 5 / S8 / T8 — actor that performs cache cascade DELETE +
  /// keystore wipe for the manual hard-wipe path. Optional so unit tests
  /// (and the constructor's default) can omit it; `hardDelete` returns a
  /// user-facing error when nil. Composition root constructs one shared
  /// instance backed by the same DB handle used by the Team feed substrate.
  private let cascadeDeleter: WorkspaceCascadeDeleter?
  private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "workspace")

  /// IDs of workspaces that have already been (or are currently being)
  /// best-effort pushed to Supabase during the current process lifetime.
  /// Self-healing path for legacy workspaces created before Item #3's
  /// `SupabaseClient.insertWorkspace` shipped — without a server row the
  /// `is_workspace_admin` RLS helper returns false and every admin write
  /// (invite_tokens, invites, etc.) is denied. We attempt one fire-and-
  /// forget upsert per workspace per session at refresh time so the user
  /// doesn't have to delete + recreate to unblock the invite flow.
  /// Idempotent on the wire (409 → already there → success).
  private var supabaseSyncedWorkspaceIDs: Set<String> = []

  init(
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = WorkspaceReader.defaultConfig(),
    databaseEncryption: EncryptionOptions? = WorkspaceReader.defaultEncryption(),
    keystoreRoot: URL = TeamKeystore.defaultRoot(),
    activeStore: ActiveWorkspaceStore,
    supabase: SupabaseClient? = nil,
    cascadeDeleter: WorkspaceCascadeDeleter? = nil
  ) {
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
    self.keystoreRoot = keystoreRoot
    self.activeStore = activeStore
    self.supabase = supabase
    self.cascadeDeleter = cascadeDeleter
  }

  /// Reads workspaces + active members from DB into state. Idempotent.
  func refresh() {
    do {
      let db = try ensureDatabase()
      let workspaces = try db.listWorkspaces(includeLeft: false)
      guard !workspaces.isEmpty else {
        state = .empty
        return
      }

      // Resolve active workspace (post-M019 first launch fills the UD key
      // via backfillIfNeeded; subsequent launches read the stored id).
      try activeStore.backfillIfNeeded(database: db)
      guard let activeID = activeStore.activeWorkspaceID,
        let active = workspaces.first(where: { $0.id == activeID })
      else {
        state = .error(message: "Couldn’t resolve active workspace.")
        return
      }

      // Self-removed detection per active workspace (Phase 5.3.E pattern).
      let allMembers = try db.readTeamMembers(workspaceID: active.id, includeRemoved: true)
      let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
      let myPubHex = priv.publicKey.rawRepresentation
        .map { String(format: "%02x", $0) }.joined()
      if let selfMember = allMembers.first(where: { $0.pubkeyHex == myPubHex }),
        selfMember.removedAt != nil
      {
        state = .removedFromActiveWorkspace(workspaceName: active.name)
        return
      }

      let activeMembers = allMembers.filter { $0.removedAt == nil }
      state = .loaded(workspaces: workspaces, active: active, members: activeMembers)

      // Self-heal pre-server-sync legacy rows. One best-effort upsert per
      // workspace per session — 201 means we filled the gap, 409 means the
      // server already had it. Any other failure logs and re-tries on the
      // next session boundary.
      ensureActiveWorkspaceSyncedToSupabase(
        workspace: active, createdByPubkey: myPubHex
      )
    } catch {
      logger.error("WorkspaceReader.refresh failed: \(String(describing: error), privacy: .public)")
      state = .error(message: userFacingMessage(for: error))
    }
  }

  /// Fire-and-forget upsert of the active workspace to Supabase. Used by
  /// `refresh` to back-fill rows for workspaces created before Item #3's
  /// `SupabaseClient.insertWorkspace` shipped — without the server row,
  /// `is_workspace_admin` returns false and every admin write (invite_tokens,
  /// invites) is denied with the «Only the workspace creator can manage
  /// invite tokens» message. Runs at most once per workspace per process
  /// lifetime (tracked via `supabaseSyncedWorkspaceIDs`).
  private func ensureActiveWorkspaceSyncedToSupabase(
    workspace: Workspace, createdByPubkey: String
  ) {
    guard let supabase else { return }
    guard !supabaseSyncedWorkspaceIDs.contains(workspace.id) else { return }
    supabaseSyncedWorkspaceIDs.insert(workspace.id)
    let id = workspace.id
    let name = workspace.name
    Task { @MainActor [weak self] in
      do {
        try await supabase.insertWorkspace(
          id: id, name: name, createdByPubkey: createdByPubkey
        )
        self?.logger.info("supabase upsertWorkspace: \(id, privacy: .public) created")
      } catch SupabaseError.conflict {
        // Server already has the row (either from a prior session that
        // synced, or another device under the same identity). Treat as
        // success — the convergent state matches the local row.
        self?.logger.info("supabase upsertWorkspace: \(id, privacy: .public) already present (409)")
      } catch {
        // Non-fatal — leave id IN the synced set so we don't spam retries
        // every refresh; user can drop + recreate the workspace if the
        // server-side row is genuinely required and the upsert keeps
        // failing for some other reason (auth, network outage, etc.).
        self?.logger.warning(
          "supabase upsertWorkspace failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  /// Creates a new workspace, syncs to Supabase, sets it as active, refreshes
  /// state. Two pre-checks before the local INSERT:
  ///
  ///  1. **Trim + non-empty + ≤80 chars** — mirrors WorkspaceService validation.
  ///  2. **Case-insensitive uniqueness** against existing non-left workspaces
  ///     (mirrors the server-side `workspaces_name_per_admin_unique` UNIQUE
  ///     (`created_by_pubkey`, `name`) constraint so the user sees the
  ///     friendly error without a round-trip).
  ///
  /// After the local commit succeeds, M027 requires a server-side `workspaces`
  /// row so the `is_workspace_admin` RLS helper returns true for the creator
  /// on every subsequent admin write (invite_tokens, invites, etc.). Without
  /// the server row, generate-invite returns 403 — the «Couldn't generate
  /// invite — Only the workspace creator can manage invite tokens» dead-end
  /// users hit during dogfooding round 3. If the server-insert fails, the
  /// local row stays and the user gets a banner explaining the divergence;
  /// they need to delete + recreate (or wait for a follow-up that retries
  /// the sync on next refresh).
  func createWorkspace(displayName: String) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
          state = .error(message: "Workspace name can’t be empty or too long.")
          return
        }

        let db = try ensureDatabase()

        // Item #5 — client-side uniqueness check against existing
        // non-left workspaces. localizedCaseInsensitiveCompare matches
        // the server-side UNIQUE (created_by_pubkey, name) constraint
        // intent without the round-trip cost.
        let existing = try db.listWorkspaces(includeLeft: false)
        if existing.contains(where: {
          $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
          state = .error(
            message: "A workspace named “\(trimmed)” already exists. Pick a different name."
          )
          return
        }

        let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
        let workspace = try svc.createWorkspace(displayName: trimmed)

        // Item #3 — server-side workspaces row. Required so
        // `is_workspace_admin(workspace_id, jwt_pubkey)` returns true
        // for any subsequent admin write (invite_tokens / invites /
        // workspace_members). Skip when supabase is nil (unit tests).
        if let supabase {
          let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
          let pubkeyHex = priv.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }.joined()
          do {
            try await supabase.insertWorkspace(
              id: workspace.id,
              name: workspace.name,
              createdByPubkey: pubkeyHex
            )
          } catch SupabaseError.conflict {
            // Server already has a row for this (admin, name) pair
            // — either a previous attempt synced and we re-tried,
            // or another device under the same identity beat us
            // to it. Either way, the row exists; treat as success.
            logger.warning("insertWorkspace 409 — server row already exists, proceeding")
          } catch {
            logger.error(
              "WorkspaceReader.insertWorkspace failed: \(String(describing: error), privacy: .public)"
            )
            state = .error(
              message:
                "Workspace created locally but couldn’t sync with the server. Invites will fail until you delete it and try again. (\(userFacingMessage(for: error)))"
            )
            return
          }
        }

        activeStore.setActive(workspace.id)
        refresh()
      } catch {
        logger.error(
          "WorkspaceReader.createWorkspace failed: \(String(describing: error), privacy: .public)"
        )
        state = .error(message: userFacingMessage(for: error))
      }
    }
  }

  /// Switches active workspace. Idempotent. Refreshes state.
  func switchActive(to workspaceID: String) {
    activeStore.setActive(workspaceID)
    refresh()
  }

  // MARK: - Track 5 / S7 E.8 — leaveWorkspace (closes S2 NIT-3)

  /// Soft-marks the specified workspace as left. If the workspace being left
  /// is currently active, re-resolves active to the next alphabetical
  /// remaining workspace (or clears active if none remain).
  ///
  /// On success: state transitions to .loaded(newActive, ...) or .empty
  ///             (if no remaining workspaces after leaving).
  /// On failure: state transitions to .error(_).
  ///
  /// S7 Stage 6 fix C-C2: accepts explicit workspaceID so callers don't have
  /// to depend on `state.active`. Prevents the "Sidebar context-menu Leave on
  /// a non-active workspace marks the *active* one instead" staleness bug
  /// when callers had setActive(wid) immediately followed by leaveActive
  /// (the setActive does not refresh the Reader's state.active).
  /// S7 Stage 6 fix M4 — synchronous: the body is local-only
  /// (WorkspaceService.markLeft + listWorkspaces + ActiveWorkspaceStore are
  /// all synchronous). The earlier `async` was a leftover from when the
  /// flow round-tripped a Supabase PATCH; now there is no awaitable work.
  func leaveWorkspace(workspaceID: String) {
    do {
      let db = try ensureDatabase()
      // Solo-admin guard: «leaving» a workspace you created when nobody else
      // ever joined would orphan the row with no possibility of rejoin (no
      // one left to re-invite you). Force the user through Delete Permanently
      // instead. UI already hides the Leave button for this case, but the
      // guard here defends sidebar-context-menu / future programmatic paths.
      let members = try db.readTeamMembers(workspaceID: workspaceID, includeRemoved: false)
      let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
      let myPubHex = priv.publicKey.rawRepresentation
        .map { String(format: "%02x", $0) }.joined()
      if members.count == 1, let me = members.first,
        me.pubkeyHex == myPubHex, me.role == .admin
      {
        state = .error(
          message:
            "You’re the only member of this workspace. Use Delete Permanently instead of leaving."
        )
        return
      }
      let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
      try svc.markLeft(workspaceID: workspaceID, at: Date())
      // Only re-resolve active when the workspace we left was the active one.
      if activeStore.activeWorkspaceID == workspaceID {
        let remaining = try svc.listWorkspaces(includeLeft: false)
          .filter { $0.id != workspaceID }
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        activeStore.setActive(remaining.first?.id)
      }
      refresh()
    } catch {
      logger.error(
        "WorkspaceReader.leaveWorkspace failed: \(String(describing: error), privacy: .public)")
      state = .error(message: userFacingMessage(for: error))
    }
  }

  /// Convenience wrapper: leave the workspace that is currently active.
  /// Reads `state.active` so the active workspace must be resolved before
  /// calling this method. Use `leaveWorkspace(workspaceID:)` for explicit ids.
  func leaveActiveWorkspace() {
    guard case .loaded(_, let active, _) = state else { return }
    leaveWorkspace(workspaceID: active.id)
  }

  // MARK: - Track 5 / S7 E.6 — rename

  /// Orchestrate workspace rename: PATCH Supabase first (RLS gate enforced
  /// server-side; only the workspace creator can rename), then local UPDATE.
  ///
  /// Returns: nil on success, otherwise a user-facing error message.
  ///
  /// S7 Stage 6 fix C-I5 + C-I8 — explicit return value lets the caller
  /// distinguish "this operation's outcome" from "current Reader state",
  /// which were previously conflated when WorkspaceNameEditor inspected
  /// state.error after the call (false positives from stale prior errors,
  /// false negatives when state transitioned to .empty mid-call). The
  /// reader still transitions state on failure for any subscribers that
  /// rely on it, but callers should prefer the returned value as the
  /// authoritative operation result.
  ///
  /// Note (C-I5 server/local divergence): if the server PATCH succeeds but
  /// the local write throws (disk full, encryption error, etc.), the
  /// returned error reflects the local failure — but the server has the
  /// new name. The caller's banner should hint at "Restart app to retry
  /// sync"; structural rollback is deferred to a future startup-sync pass.
  func rename(workspaceID: String, newName: String) async -> String? {
    do {
      // Local-first rename (mirrors `delete` after the round-5 fix and
      // `leaveWorkspace` discipline). The server-first ordering doc-comment
      // above (C-I5 carry-over) was the rename twin of the delete deadlock
      // — `patchWorkspaceName` throws `.noRowsAffected` for legacy
      // workspaces whose server row was never created, so the local UPDATE
      // never ran and the user saw the stale name forever. Local commit
      // first; server convergence is best-effort under do/catch.
      let db = try ensureDatabase()
      let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
      try svc.updateName(workspaceID: workspaceID, newName: newName)
      refresh()
      if let supabase {
        do {
          try await supabase.patchWorkspaceName(id: workspaceID, name: newName)
        } catch SupabaseError.noRowsAffected {
          // Workspace missing server-side (pre-`insertWorkspace` legacy
          // row). Self-heal upsert in `refresh` will create it on next
          // tick with the now-renamed value; convergent state.
          logger.info(
            "patchWorkspaceName 0 rows — workspace not on server (legacy); rename committed locally"
          )
        } catch {
          logger.warning(
            "patchWorkspaceName failed: \(String(describing: error), privacy: .public) — local rename committed; server will converge later"
          )
        }
      }
      return nil
    } catch {
      logger.error("WorkspaceReader.rename failed: \(String(describing: error), privacy: .public)")
      let msg = userFacingMessage(for: error)
      state = .error(message: msg)
      return msg
    }
  }

  // MARK: - Track 5 / S7 E.7 — delete (admin-only)

  /// Orchestrate workspace delete (admin-only via server RLS gate).
  /// PATCH Supabase first (soft-delete), then local cascade DELETE.
  ///
  /// If the deleted workspace was active, re-resolves active to the next
  /// alphabetical remaining workspace (or clears active if none remain).
  ///
  /// Returns: nil on success, otherwise a user-facing error message.
  ///
  /// S7 Stage 6 fix C-I5 + C-I8 — explicit return value (mirrors rename).
  func delete(workspaceID: String) async -> String? {
    do {
      // Local-first delete (mirrors `leaveWorkspace` discipline). The local
      // SQLCipher DB is the source of truth; the server-side
      // `workspaces.deleted_at_ms` PATCH below is best-effort convergence.
      //
      // Earlier server-first pattern broke dogfooding: workspaces created
      // before Item #3 (`SupabaseClient.insertWorkspace`) landed never had a
      // server row, so `softDeleteWorkspace`'s `Content-Range: */0` threw
      // `.noRowsAffected` → state went to `.error("Only the workspace
      // creator can perform this action")` → local delete never ran → user
      // saw the workspace «vanish» (actionButtonsRow stopped rendering and
      // its `.sheet` modifier unmounted with it) but the row sat in
      // SQLCipher, so the next `refresh()` resurrected the entire workspace
      // list — exactly the «Try again brought them back» symptom from
      // dogfooding round 5.
      let db = try ensureDatabase()
      let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
      try svc.softDelete(workspaceID: workspaceID, at: Date())
      if activeStore.activeWorkspaceID == workspaceID {
        let remaining = try svc.listWorkspaces(includeLeft: false)
          .filter { $0.id != workspaceID }
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        activeStore.setActive(remaining.first?.id)
      }
      refresh()
      // Best-effort server convergence. Failure here does NOT roll back the
      // local delete — divergence is logged but the user's perceived state
      // (workspace gone) is preserved. Out-of-band cleanup will reconcile
      // server-side later (cron / next session).
      if let supabase {
        do {
          try await supabase.softDeleteWorkspace(id: workspaceID)
        } catch SupabaseError.noRowsAffected {
          // No matching row server-side (workspace was never POSTed — e.g.,
          // created before Item #3 server-INSERT shipped). Local delete
          // already committed; nothing further to do.
          logger.info(
            "softDeleteWorkspace 0 rows — workspace not present server-side (pre-server-sync legacy row)"
          )
        } catch {
          logger.warning(
            "softDeleteWorkspace server PATCH failed: \(String(describing: error), privacy: .public) — local delete committed; server will converge later"
          )
        }
      }
      return nil
    } catch {
      logger.error("WorkspaceReader.delete failed: \(String(describing: error), privacy: .public)")
      let msg = userFacingMessage(for: error)
      state = .error(message: msg)
      return msg
    }
  }

  // MARK: - Track 5 / S8 / T8 — hardDelete (manual cache wipe)

  /// Orchestrate manual hard-wipe of local workspace cache. Delegates to the
  /// shared `WorkspaceCascadeDeleter` actor and refreshes local state.
  /// If the wiped workspace was active, re-resolves active to the next
  /// alphabetical remaining workspace (or clears active if none remain).
  ///
  /// **Audit invariant (sec C2):** Preserves `team_keys` + `team_members`
  /// rows. Only cache + the workspace row + per-workspace keystore folder
  /// are wiped. Mirrors `WorkspaceService.softDelete` (Workspace.swift
  /// line ~168) audit invariant.
  ///
  /// Returns: nil on success, otherwise a user-facing error message
  /// (matches `delete` / `rename` per-op error contract from S7 fix C-I5).
  ///
  /// Closes S7 Stage 6 fix C-I7 — `LeaveWorkspaceConfirmationModal` honest
  /// copy promised an on-device retention pruner; this is the manual side.
  func hardDelete(workspaceID: String) async -> String? {
    guard let cascadeDeleter else {
      let msg = "Cache wipe is unavailable. Please restart the app."
      state = .error(message: msg)
      return msg
    }
    do {
      try await cascadeDeleter.execute(workspaceID: workspaceID)
      if activeStore.activeWorkspaceID == workspaceID {
        let db = try ensureDatabase()
        let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
        let remaining = try svc.listWorkspaces(includeLeft: false)
          .filter { $0.id != workspaceID }
          .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        activeStore.setActive(remaining.first?.id)
      }
      refresh()
      return nil
    } catch {
      logger.error(
        "WorkspaceReader.hardDelete failed: \(String(describing: error), privacy: .public)")
      let msg = userFacingMessage(for: error)
      state = .error(message: msg)
      return msg
    }
  }

  // MARK: - Internals

  private func ensureDatabase() throws -> LeafCore.Database {
    if let database { return database }
    let db = try LeafCore.Database.openForWrite(
      at: databaseURL,
      config: databaseConfig,
      encryption: databaseEncryption
    )
    self.database = db
    return db
  }

  private func userFacingMessage(for error: Error) -> String {
    if let leafErr = error as? LeafError {
      switch leafErr {
      case .invalidPayload:
        return "Workspace name can’t be empty or too long."
      case .keyFileUnavailable, .keyFileCorrupted:
        return "Couldn’t access local keystore. Try restarting the app."
      case .keychainUnavailable:
        return "Couldn’t generate secure random data. Try again."
      default:
        return "Couldn’t complete the operation. See Console for details."
      }
    }
    if let supErr = error as? SupabaseError {
      switch supErr {
      case .forbidden, .noRowsAffected:
        // S7 Stage 6 fix C-I9 — `noRowsAffected` is the silent
        // PostgREST 204 outcome when the RLS USING-clause filters out
        // the row (non-creator UPDATE / DELETE). User-facing message
        // mirrors the explicit 403 path.
        return "Only the workspace creator can perform this action."
      case .transport(let reason):
        return "Network error: \(reason)"
      default:
        return "Server error. Try again later."
      }
    }
    return "Couldn’t complete the operation. See Console for details."
  }

  nonisolated private static func defaultConfig() -> DatabaseConfig {
    #if LEAF_PROD
      return ProdConfigs.database
    #else
      return .weakDefaults
    #endif
  }

  nonisolated private static func defaultEncryption() -> EncryptionOptions? {
    #if LEAF_PROD
      return EncryptionOptions(
        keyProvider: .callback { @Sendable in
          try FileKeyStore.fetchOrCreate()
        },
        preKeyPragmas: ProdConfigs.sqlcipherPragmasPreKey,
        postKeyPragmas: ProdConfigs.sqlcipherPragmasPostKey
      )
    #else
      return nil
    #endif
  }
}
