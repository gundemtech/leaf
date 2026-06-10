//
//  InviteTokensReader.swift
//  Leaf
//
//  M027 invite-redesign — @Observable wrapper around InviteTokenService.
//  State machine drives GenerateInviteSheet + ActiveTokensSection.
//  Mirrors InviteOutboxReader (Phase 5.2.D) lazy-init pattern.
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
final class InviteTokensReader {
  enum State: Equatable {
    case idle
    case loading
    case loaded(active: [InviteToken])
    case generating
    case ready(InviteToken)
    case error(message: String)
  }

  private(set) var state: State = .idle

  private var service: InviteTokenService?
  /// Workspace id the cached `service` was constructed against. Invalidates
  /// the cache when the user switches workspaces — without this the
  /// `InviteTokenService` keeps its first-seen `workspaceID` private,
  /// `listActive()` returns rows from the wrong workspace, and active
  /// tokens leak across the sidebar switcher (dogfooding round 6: invite
  /// "uyava" generated on workspace "acme" appeared verbatim under "5555").
  private var cachedServiceWorkspaceID: String?
  private var database: LeafCore.Database?

  private let supabase: SupabaseClient
  private let workspaceReader: WorkspaceReader
  private let activeWorkspaceStore: ActiveWorkspaceStore
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?
  private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "invite-tokens")

  /// Upper bound on the `refreshFromServer` round-trip before the UI gives up
  /// and shows an error rather than an indefinite spinner. Comfortably above a
  /// healthy request yet well under the retry loop's worst-case wall-clock.
  private static let networkTimeoutSeconds = 30

  init(
    supabase: SupabaseClient,
    workspaceReader: WorkspaceReader,
    activeWorkspaceStore: ActiveWorkspaceStore,
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = InviteTokensReader.defaultConfig(),
    databaseEncryption: EncryptionOptions? = InviteTokensReader.defaultEncryption()
  ) {
    self.supabase = supabase
    self.workspaceReader = workspaceReader
    self.activeWorkspaceStore = activeWorkspaceStore
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
  }

  // MARK: - Lifecycle

  /// Loads active tokens for the currently-active workspace. Called on
  /// Team → Members open + after every generate/delete to refresh.
  func refresh() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let svc = try self.ensureService()
        state = .loading
        // Bound the server round-trip so a stalled request (slow server, wedged
        // auth bootstrap, retry-loop backoff) can't pin "Refreshing pending
        // invites…" forever — surface .error instead. listActive() below is a
        // local SQLCipher read, so it stays outside the deadline.
        _ = try await withTimeout(.seconds(InviteTokensReader.networkTimeoutSeconds)) {
          try await svc.refreshFromServer()
        }
        let active = try svc.listActive()
        state = .loaded(active: active)
      } catch {
        logger.error("refresh error: \(String(describing: error), privacy: .public)")
        state = .error(message: friendlyMessage(for: error))
      }
    }
  }

  func generate(label: String?, ttlSeconds: Int, singleUse: Bool) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      state = .generating
      do {
        let svc = try self.ensureService()
        // Pre-flight: ensure the active workspace row exists server-side
        // BEFORE the invite_tokens INSERT. RLS `is_workspace_admin`
        // checks `workspaces.created_by_pubkey == jwt.pubkey`, so the
        // server row must be present or the INSERT 403s. Awaiting here
        // (vs. WorkspaceReader's fire-and-forget refresh upsert) closes
        // the race window between cold-launch refresh and the user
        // tapping Generate. Idempotent: 409 means the row's already
        // there, treated as success.
        try await self.ensureActiveWorkspaceSyncedToSupabase()
        let token = try await svc.generate(
          label: label, ttlSeconds: ttlSeconds, singleUse: singleUse)
        state = .ready(token)
      } catch {
        logger.error("generate error: \(String(describing: error), privacy: .public)")
        state = .error(message: friendlyMessage(for: error))
      }
    }
  }

  /// Best-effort server-side upsert of the active workspace row. Throws on
  /// transport / auth errors so the caller surfaces them via the same
  /// `friendlyMessage` path; swallows `SupabaseError.conflict` because that
  /// only means the row's already where we want it to be.
  ///
  /// Resolves all three required fields (id / name / created_by_pubkey)
  /// directly from `WorkspaceReader.state.loaded.active` + a fresh
  /// `IdentityService.ensureLocalIdentity` read — `InviteTokenService`
  /// keeps `workspaceID` and `createdByPubkeyHex` private, so we re-derive
  /// rather than expose its internals.
  private func ensureActiveWorkspaceSyncedToSupabase() async throws {
    guard
      case .loaded(_, let active, _) = workspaceReader.state,
      active.id == activeWorkspaceStore.activeWorkspaceID
    else {
      // Reader state hasn't caught up to the active workspace yet —
      // skip the upsert here and let the invite_tokens INSERT speak for
      // itself. The fire-and-forget upsert in WorkspaceReader.refresh
      // will catch up on the next state transition.
      return
    }
    let pubkeyHex: String
    do {
      let priv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
      pubkeyHex = priv.publicKey.rawRepresentation
        .map { String(format: "%02x", $0) }.joined()
    } catch {
      // Identity not yet provisioned (cold-launch race) — skip; the
      // invite INSERT will surface a clearer auth error if we're truly
      // not authenticated.
      logger.warning(
        "ensureActiveWorkspaceSyncedToSupabase: identity unresolved, skipping upsert (\(String(describing: error), privacy: .public))"
      )
      return
    }
    logger.info(
      "upsert preflight workspace=\(active.id, privacy: .public) pubkey=\(pubkeyHex.prefix(16), privacy: .public)…"
    )
    do {
      try await supabase.insertWorkspace(
        id: active.id, name: active.name, createdByPubkey: pubkeyHex
      )
      logger.info("upsert preflight: 201 created")
    } catch SupabaseError.conflict {
      // 409 means the row's PK or (created_by_pubkey, name) UNIQUE
      // matched something server-side. PK match against the SAME pubkey
      // is convergent success. PK match against a DIFFERENT pubkey
      // (e.g., legacy row created under a prior identity that survived
      // local wipe) leaves the server's `created_by_pubkey` as the OLD
      // one — `is_workspace_admin` then returns false for the NEW JWT
      // pubkey claim, and the subsequent `invite_tokens.INSERT` 403s
      // with the same friendly message regardless. We swallow .conflict
      // optimistically and let the invite INSERT speak for itself — if
      // it actually fails, surface the diagnostic so the user knows
      // delete + recreate is the recovery path.
      logger.info("upsert preflight: 409 — row already exists server-side")
    } catch {
      // Non-conflict failure (e.g., 403 because JWT pubkey claim is null
      // — Auth Hook didn't pick up registration; or .transport on network
      // blip). Surface a clearer message than the generic «manage invite
      // tokens» so the user knows it's the workspace-sync step, not the
      // permission gate, that's the actual fault.
      logger.error(
        "upsert preflight failed: \(String(describing: error), privacy: .public)"
      )
      throw LeafError.workspaceSyncFailed(
        reason:
          "Couldn't sync workspace to server: \(String(describing: error)). Try Team → Settings → Delete Permanently and recreate."
      )
    }
  }

  func delete(code: String) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let svc = try self.ensureService()
        try await svc.delete(code: code)
        // Refresh after delete to update the Active list.
        let active = try svc.listActive()
        state = .loaded(active: active)
      } catch {
        logger.error("delete error: \(String(describing: error), privacy: .public)")
        state = .error(message: friendlyMessage(for: error))
      }
    }
  }

  /// Returns the [Generate] flow back to idle so the sheet picks up a fresh
  /// label/TTL form on next open after a successful Done dismissal.
  func dismissReady() {
    state = .idle
  }

  // MARK: - Lazy init

  private func ensureService() throws -> InviteTokenService {
    guard let workspaceID = activeWorkspaceStore.activeWorkspaceID else {
      throw LeafError.databaseUnavailable
    }
    // Reuse the cached service only when it was constructed against the
    // currently-active workspace. Sidebar switcher → different active id →
    // rebuild against the new workspace; otherwise listActive / generate /
    // delete all run against the wrong `workspace_id` and the user sees
    // tokens from one workspace bleed into another's Active list.
    if let svc = service, cachedServiceWorkspaceID == workspaceID {
      return svc
    }
    let db = try ensureDatabase()
    // Self pubkey via IdentityService — same source the JWT pubkey claim
    // is derived from, so `created_by_pubkey == jwt.pubkey` RLS holds.
    // Earlier shape read `members.first` ordered by `added_at_ms ASC`,
    // which on invitee devices is the admin's row (workspace creator's
    // earlier timestamp), not self. RLS masks the misbehaviour today but
    // the code carried a future foot-gun.
    let selfPriv = try IdentityService.ensureLocalIdentity(at: TeamKeystore.defaultRoot())
    let selfPubHex = selfPriv.publicKey.rawRepresentation
      .map { String(format: "%02x", $0) }.joined()
    let svc = InviteTokenService(
      database: db,
      supabase: supabase,
      workspaceID: workspaceID,
      createdByPubkeyHex: selfPubHex
    )
    service = svc
    cachedServiceWorkspaceID = workspaceID
    return svc
  }

  private func ensureDatabase() throws -> LeafCore.Database {
    if let db = database { return db }
    let db = try LeafCore.Database.openForWrite(
      at: databaseURL, config: databaseConfig, encryption: databaseEncryption
    )
    database = db
    return db
  }

  // MARK: - Composition root defaults

  nonisolated static func defaultConfig() -> DatabaseConfig {
    #if LEAF_PROD
      return ProdConfigs.database
    #else
      return .weakDefaults
    #endif
  }

  nonisolated static func defaultEncryption() -> EncryptionOptions? {
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

  // MARK: - Helpers

  private func friendlyMessage(for error: Error) -> String {
    if let tokenErr = error as? InviteTokenError, tokenErr == .maxActiveTokensReached {
      return "Max active tokens reached (10). Delete one to create another."
    }
    if error is TimeoutError {
      return "Timed out refreshing invites. Check your connection and try again."
    }
    if let leafErr = error as? LeafError {
      // Distinguish workspace-sync upsert failure from the generic «manage
      // invite tokens» 403 so the user knows it's the workspace-sync gate
      // that's broken, not their permission. The recovery path is to
      // delete + recreate the legacy workspace.
      if case .workspaceSyncFailed(let reason) = leafErr {
        return reason
      }
      return leafErr.localizedDescription
    }
    if let supabaseErr = error as? SupabaseError {
      switch supabaseErr {
      case .forbidden: return "Only the workspace creator can manage invite tokens."
      case .noRowsAffected: return "Token not found or already deleted."
      case .transport(let reason): return "Network error: \(reason)"
      case .unauthorized: return "Not signed in to Supabase. Restart the app."
      case .authBootstrapFailed(let reason): return "Auth bootstrap failed: \(reason)"
      case .identityClaimMissing:
        return "JWT missing pubkey claim — Auth Hook race. Restart the app."
      case .decoding(let reason): return "Response decoding failed: \(reason)"
      case .unexpected(let status): return "Unexpected server status \(status)."
      case .badRequest: return "Bad request — client sent invalid payload."
      case .notFound: return "Endpoint not found — Edge Function may not be deployed."
      case .conflict: return "Conflict — token may already exist."
      case .rateLimited: return "Rate limited. Wait and try again."
      case .serverError: return "Server error (5xx)."
      case .pubkeyAlreadyRegistered: return "Pubkey already registered to another auth_id."
      case .inviteNotResolvable: return "Invite no longer valid."
      case .gone(let code): return "Invite no longer available (\(code))."
      }
    }
    return "Something went wrong: \(String(describing: error).prefix(120))"
  }
}
