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
import Observation
import OSLog
import LeafCore
#if LEAF_PROD
import LeafCorePrivate
#endif

@MainActor
@Observable
final class WorkspaceReader {
    enum State: Equatable {
        case loading
        case empty                                                  // no workspaces — onboarding
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
    private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "workspace")

    init(
        databaseURL: URL = DatabasePath.defaultURL(),
        databaseConfig: DatabaseConfig = WorkspaceReader.defaultConfig(),
        databaseEncryption: EncryptionOptions? = WorkspaceReader.defaultEncryption(),
        keystoreRoot: URL = TeamKeystore.defaultRoot(),
        activeStore: ActiveWorkspaceStore,
        supabase: SupabaseClient? = nil
    ) {
        self.databaseURL = databaseURL
        self.databaseConfig = databaseConfig
        self.databaseEncryption = databaseEncryption
        self.keystoreRoot = keystoreRoot
        self.activeStore = activeStore
        self.supabase = supabase
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
                  let active = workspaces.first(where: { $0.id == activeID }) else {
                state = .error(message: "Couldn’t resolve active workspace.")
                return
            }

            // Self-removed detection per active workspace (Phase 5.3.E pattern).
            let allMembers = try db.readTeamMembers(workspaceID: active.id, includeRemoved: true)
            let priv = try IdentityService.ensureLocalIdentity(at: keystoreRoot)
            let myPubHex = priv.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined()
            if let selfMember = allMembers.first(where: { $0.pubkeyHex == myPubHex }),
               selfMember.removedAt != nil {
                state = .removedFromActiveWorkspace(workspaceName: active.name)
                return
            }

            let activeMembers = allMembers.filter { $0.removedAt == nil }
            state = .loaded(workspaces: workspaces, active: active, members: activeMembers)
        } catch {
            logger.error("WorkspaceReader.refresh failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
        }
    }

    /// Creates a new workspace, sets it as active, refreshes state.
    func createWorkspace(displayName: String) {
        do {
            let db = try ensureDatabase()
            let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
            let workspace = try svc.createWorkspace(displayName: displayName)
            activeStore.setActive(workspace.id)
            refresh()
        } catch {
            logger.error("WorkspaceReader.createWorkspace failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
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
    func leaveWorkspace(workspaceID: String) async {
        do {
            let db = try ensureDatabase()
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
            logger.error("WorkspaceReader.leaveWorkspace failed: \(String(describing: error), privacy: .public)")
            state = .error(message: userFacingMessage(for: error))
        }
    }

    /// Convenience wrapper: leave the workspace that is currently active.
    /// Reads `state.active` so the active workspace must be resolved before
    /// calling this method. Use `leaveWorkspace(workspaceID:)` for explicit ids.
    func leaveActiveWorkspace() async {
        guard case .loaded(_, let active, _) = state else { return }
        await leaveWorkspace(workspaceID: active.id)
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
        guard let supabase else {
            let msg = "No network connection. Please sign in first."
            state = .error(message: msg)
            return msg
        }
        do {
            try await supabase.patchWorkspaceName(id: workspaceID, name: newName)
            let db = try ensureDatabase()
            let svc = WorkspaceService(database: db, keystoreRoot: keystoreRoot)
            try svc.updateName(workspaceID: workspaceID, newName: newName)
            refresh()
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
        guard let supabase else {
            let msg = "No network connection. Please sign in first."
            state = .error(message: msg)
            return msg
        }
        do {
            try await supabase.softDeleteWorkspace(id: workspaceID)
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
            return nil
        } catch {
            logger.error("WorkspaceReader.delete failed: \(String(describing: error), privacy: .public)")
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
