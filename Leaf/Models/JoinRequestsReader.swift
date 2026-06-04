//
//  JoinRequestsReader.swift
//  Leaf
//
//  M027 invite-redesign — @Observable wrapper around JoinRequestService.
//  Drives both admin's PendingRequestsSection queue + invitee's
//  JoinRequestWaitingCard state machine.
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
final class JoinRequestsReader {
  enum AdminQueueState: Equatable {
    case idle
    case loading
    case loaded([JoinRequest])
    case error(message: String)
  }

  enum InviteeWaitingState: Equatable {
    case idle
    case submitting
    case pending(JoinRequest)
    /// Approved server-side, materialisation in flight (ECDH+decrypt+
    /// keystore+DB writes). Transitions to `.joined` on success.
    case approved(JoinRequest)
    /// Terminal good — workspace materialised locally and ready to use.
    /// Carries id + name so the waiting card can both render «Joined
    /// "<name>"» AND trigger `WorkspaceReader.switchActive(to:)` to put
    /// the freshly-joined workspace in front before auto-dismissing.
    case joined(workspaceID: String, workspaceName: String)
    case declined
    case cancelled
    case expired
    case error(message: String)
  }

  private(set) var adminQueue: AdminQueueState = .idle
  private(set) var inviteeState: InviteeWaitingState = .idle

  /// Per-request in-flight set for Approve / Decline tap dedupe. Surfaces
  /// to PendingRequestsSection via `isInFlight(_:)` so the row's buttons
  /// gate `.disabled` while the network round-trip + ECDH+seal pipeline
  /// for that request is mid-flight. Earlier shape kept buttons enabled —
  /// double-tap landed two POSTs against the same `request_id`, second
  /// 400'd / 410'd after the first committed, user saw an error banner
  /// over a successfully-approved row.
  private(set) var inFlightRequestIDs: Set<String> = []
  /// True while `approveAll` / `declineAll` is iterating. Bulk buttons gate
  /// `.disabled` to avoid two concurrent loops racing on `adminQueue` writes.
  private(set) var isBulkOpRunning: Bool = false
  /// True while invitee-side `submit` POST is in flight. JoinWorkspaceByCodeSheet
  /// Send button gates `.disabled` — trackpad bounce / double-tap → single POST.
  private(set) var isSubmitInFlight: Bool = false
  /// True while invitee-side `cancelOwn` PATCH is in flight. JoinRequestWaitingCard
  /// Cancel button gates `.disabled`.
  private(set) var isCancelOwnInFlight: Bool = false

  private var service: JoinRequestService?
  private var database: LeafCore.Database?
  /// Request IDs whose materialisation is in-flight or already committed.
  /// Dedup so the WaitingCard's 30s poll loop doesn't re-trigger ECDH +
  /// duplicate-INSERT churn on every tick after a .approved transition.
  private var materialisationInFlightRequestIDs: Set<String> = []

  /// Late-bound roster-refresh hook. The composition root (`LeafApp.onAppear`)
  /// wires this to `WorkspaceReader.refresh()` so the admin's Team roster
  /// updates immediately after an approve — which now inserts the invitee into
  /// the local `team_members` (Bug B). The invitee side self-heals via the
  /// waiting card's `switchActive → refresh`, so it needs no hook here.
  private var onRosterChanged: (@MainActor () -> Void)?

  /// Composition-root wiring (mirrors the `InviteURLHandler.wireM027` late-bind
  /// pattern — both readers are app-lifetime `@State` in `LeafApp`).
  func wireRosterRefresh(_ callback: @escaping @MainActor () -> Void) {
    onRosterChanged = callback
  }

  private let supabase: SupabaseClient
  private let activeWorkspaceStore: ActiveWorkspaceStore
  private let databaseURL: URL
  private let databaseConfig: DatabaseConfig
  private let databaseEncryption: EncryptionOptions?
  private let keystoreRoot: URL
  private let inviteKDF: any InviteKDF
  private let inviteBlobCodec: any InviteBlobCodec
  private let logger = Logger(subsystem: "tech.gundem.leaf.app", category: "join-requests")

  init(
    supabase: SupabaseClient,
    activeWorkspaceStore: ActiveWorkspaceStore,
    databaseURL: URL = DatabasePath.defaultURL(),
    databaseConfig: DatabaseConfig = JoinRequestsReader.defaultConfig(),
    databaseEncryption: EncryptionOptions? = JoinRequestsReader.defaultEncryption(),
    keystoreRoot: URL = TeamKeystore.defaultRoot(),
    inviteKDF: any InviteKDF = JoinRequestsReader.defaultInviteKDF(),
    inviteBlobCodec: any InviteBlobCodec = JoinRequestsReader.defaultInviteBlobCodec()
  ) {
    self.supabase = supabase
    self.activeWorkspaceStore = activeWorkspaceStore
    self.databaseURL = databaseURL
    self.databaseConfig = databaseConfig
    self.databaseEncryption = databaseEncryption
    self.keystoreRoot = keystoreRoot
    self.inviteKDF = inviteKDF
    self.inviteBlobCodec = inviteBlobCodec
  }

  // MARK: - Admin queue API

  func refreshAdminQueue() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let svc = try self.ensureService()
        guard let workspaceID = self.activeWorkspaceStore.activeWorkspaceID else {
          self.adminQueue = .loaded([])
          return
        }
        self.adminQueue = .loading
        let pending = try await svc.listPending(workspaceID: workspaceID)
        self.adminQueue = .loaded(pending)
      } catch {
        self.logger.error("refreshAdminQueue: \(String(describing: error), privacy: .public)")
        self.adminQueue = .error(message: friendlyMessage(for: error))
      }
    }
  }

  /// True while the per-row `approve`/`decline` for `requestID` is mid-flight.
  /// Surfaces to `PendingRequestsSection` for `.disabled` gating on the row's
  /// Approve / Decline buttons.
  func isInFlight(_ requestID: String) -> Bool {
    inFlightRequestIDs.contains(requestID)
  }

  func approve(request: JoinRequest) {
    // Per-request inflight guard. Second tap on the same row while the
    // first is mid-pipeline becomes a no-op instead of pumping a duplicate
    // ECDH+seal+POST round-trip.
    guard !inFlightRequestIDs.contains(request.requestID) else { return }
    inFlightRequestIDs.insert(request.requestID)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.inFlightRequestIDs.remove(request.requestID) }
      do {
        let svc = try self.ensureService()
        try await svc.approve(
          workspaceID: request.workspaceID,
          requestID: request.requestID,
          inviteePubkeyHex: request.inviteePubkeyHex,
          inviteeDisplayName: request.inviteeDisplayName
        )
        self.refreshAdminQueue()
        // Invitee now in the local roster — refresh the admin's Team view.
        self.onRosterChanged?()
      } catch {
        self.logger.error("approve: \(String(describing: error), privacy: .public)")
        self.adminQueue = .error(message: friendlyMessage(for: error))
      }
    }
  }

  func decline(requestID: String) {
    guard !inFlightRequestIDs.contains(requestID) else { return }
    inFlightRequestIDs.insert(requestID)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.inFlightRequestIDs.remove(requestID) }
      do {
        let svc = try self.ensureService()
        try await svc.decline(requestID: requestID)
        self.refreshAdminQueue()
      } catch {
        self.logger.error("decline: \(String(describing: error), privacy: .public)")
        self.adminQueue = .error(message: friendlyMessage(for: error))
      }
    }
  }

  func approveAll(requests: [JoinRequest]) {
    // Bulk-button inflight guard so a quick double-tap doesn't spawn two
    // concurrent loops racing on `adminQueue` writes.
    guard !isBulkOpRunning else { return }
    isBulkOpRunning = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isBulkOpRunning = false }
      // Refresh the admin roster once at the end — even on partial failure,
      // approvals before the throw already committed local member rows.
      defer { self.onRosterChanged?() }
      do {
        let svc = try self.ensureService()
        for req in requests {
          try await svc.approve(
            workspaceID: req.workspaceID,
            requestID: req.requestID,
            inviteePubkeyHex: req.inviteePubkeyHex,
            inviteeDisplayName: req.inviteeDisplayName
          )
        }
        self.refreshAdminQueue()
      } catch {
        self.logger.error("approveAll: \(String(describing: error), privacy: .public)")
        self.adminQueue = .error(message: friendlyMessage(for: error))
      }
    }
  }

  func declineAll(requestIDs: [String]) {
    guard !isBulkOpRunning else { return }
    isBulkOpRunning = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isBulkOpRunning = false }
      do {
        let svc = try self.ensureService()
        for id in requestIDs {
          try await svc.decline(requestID: id)
        }
        self.refreshAdminQueue()
      } catch {
        self.logger.error("declineAll: \(String(describing: error), privacy: .public)")
        self.adminQueue = .error(message: friendlyMessage(for: error))
      }
    }
  }

  // MARK: - Invitee waiting-card API

  func submit(workspaceID: String? = nil, code: String, displayName: String) {
    // Trackpad bounce / double-tap on Send → single POST. `inviteeState`
    // also already gates UI (`.submitting`) but this guard short-circuits
    // re-entries before they even mutate state.
    guard !isSubmitInFlight else { return }
    isSubmitInFlight = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isSubmitInFlight = false }
      self.inviteeState = .submitting
      do {
        let svc = try self.ensureService()
        let row = try await svc.submit(
          workspaceID: workspaceID, code: code, displayName: displayName
        )
        self.inviteeState = .pending(row)
      } catch {
        self.logger.error("submit: \(String(describing: error), privacy: .public)")
        self.inviteeState = .error(message: friendlyMessage(for: error))
      }
    }
  }

  func cancelOwn(requestID: String) {
    guard !isCancelOwnInFlight else { return }
    isCancelOwnInFlight = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.isCancelOwnInFlight = false }
      do {
        let svc = try self.ensureService()
        try await svc.cancel(requestID: requestID)
        self.inviteeState = .cancelled
      } catch {
        self.logger.error("cancelOwn: \(String(describing: error), privacy: .public)")
        self.inviteeState = .error(message: friendlyMessage(for: error))
      }
    }
  }

  /// Polls own request status (30s tick from JoinRequestWaitingCard).
  /// Transitions inviteeState as the server-side status flips. On the
  /// first `.approved` row observed for a given request, kicks off the
  /// post-approval materialisation pipeline (`JoinRequestService.acceptApproved`).
  /// Subsequent polls for the same `requestID` short-circuit via
  /// `materialisationInFlightRequestIDs`.
  ///
  /// `async` so the caller's structured `.task` lifetime owns the in-flight
  /// HTTP + ECDH pipeline. Earlier shape spawned a detached `Task { ... }`
  /// here, which escaped `.task` cancellation on sheet dismiss — leading to
  /// post-dismiss `inviteeState` writes and (worst case) silent workspace
  /// materialisation after the user gave up. Keep this function `async`;
  /// the poll loop in `JoinRequestWaitingCard.startPoll` awaits it directly
  /// inside its `.task` so SwiftUI cancels everything atomically.
  func pollOwn(requestID: String) async {
    do {
      let svc = try ensureService()
      guard let row = try await svc.fetchOwn(requestID: requestID) else {
        // Row vanished — treat as cancelled (most likely path: invitee
        // cancelled from another device, OR admin hard-deleted token
        // and request cascades).
        inviteeState = .cancelled
        return
      }
      switch row.status {
      case .pending: inviteeState = .pending(row)
      case .approved:
        // Dedup: keep the first .approved observation as the trigger;
        // future polls just refresh the visible state without re-running
        // ECDH + INSERTs.
        if materialisationInFlightRequestIDs.insert(row.requestID).inserted {
          inviteeState = .approved(row)
          await materialiseApproved(row: row, service: svc)
        }
      case .declined: inviteeState = .declined
      case .cancelled: inviteeState = .cancelled
      case .expired: inviteeState = .expired
      }
    } catch {
      logger.error("pollOwn: \(String(describing: error), privacy: .public)")
      inviteeState = .error(message: friendlyMessage(for: error))
    }
  }

  /// Runs the invitee-side post-approval materialisation. Stays on the
  /// approved state during the in-flight window so the WaitingCard can
  /// render «Approved — joining…»; transitions to `.joined(workspaceName:)`
  /// on success, or `.error` on local failure. `acceptApproved` is now total +
  /// idempotent (converges from any prior local state, never throws
  /// `inviteAlreadyAccepted`), so a re-tick / relaunch re-run is a safe no-op.
  private func materialiseApproved(row: JoinRequest, service svc: JoinRequestService) async {
    do {
      let accepted = try await svc.acceptApproved(request: row)
      self.inviteeState = .joined(
        workspaceID: accepted.orgID, workspaceName: accepted.orgName)
    } catch {
      self.logger.error(
        "materialiseApproved: \(String(describing: error), privacy: .public)")
      // Allow a future retry — drop the dedup mark.
      self.materialisationInFlightRequestIDs.remove(row.requestID)
      self.inviteeState = .error(message: friendlyMessage(for: error))
    }
  }

  func resetInviteeState() {
    inviteeState = .idle
    materialisationInFlightRequestIDs.removeAll()
  }

  // MARK: - Lazy init

  private func ensureService() throws -> JoinRequestService {
    if let svc = service { return svc }
    let db = try ensureDatabase()
    let svc = JoinRequestService(
      database: db,
      supabase: supabase,
      inviteKDF: inviteKDF,
      inviteBlobCodec: inviteBlobCodec,
      keystoreRoot: keystoreRoot
    )
    service = svc
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

  nonisolated static func defaultInviteKDF() -> any InviteKDF {
    #if LEAF_PROD
      return ProdInviteKDF()
    #else
      return UnimplementedInviteKDF()
    #endif
  }

  nonisolated static func defaultInviteBlobCodec() -> any InviteBlobCodec {
    #if LEAF_PROD
      return ProdInviteBlobCodec()
    #else
      return UnimplementedInviteBlobCodec()
    #endif
  }

  // MARK: - Helpers

  private func friendlyMessage(for error: Error) -> String {
    if let leafErr = error as? LeafError {
      return leafErr.localizedDescription
    }
    if let supabaseErr = error as? SupabaseError {
      switch supabaseErr {
      case .forbidden: return "Not authorized for this action."
      case .noRowsAffected: return "This invite is no longer valid."
      case .transport(let reason): return "Network error: \(reason)"
      case .unauthorized: return "Not signed in to Supabase. Restart the app."
      case .authBootstrapFailed(let reason): return "Auth bootstrap failed: \(reason)"
      case .identityClaimMissing:
        return "JWT missing pubkey claim — Auth Hook race. Restart the app."
      case .decoding(let reason): return "Response decoding failed: \(reason)"
      case .unexpected(let status): return "Unexpected server status \(status)."
      case .badRequest: return "Bad request — client sent invalid payload."
      case .notFound: return "Endpoint not found — Edge Function may not be deployed."
      case .conflict: return "Conflict — duplicate request."
      case .rateLimited: return "Rate limited. Wait and try again."
      case .serverError: return "Server error (5xx)."
      case .pubkeyAlreadyRegistered: return "Pubkey collision."
      case .inviteNotResolvable: return "Invite expired or claimed."
      case .gone(let code): return friendlyInviteGoneMessage(for: code)
      }
    }
    return "Something went wrong: \(String(describing: error).prefix(120))"
  }

  /// Maps the M027 `create_join_request` Edge Function's 410 error codes
  /// (sourced from `consume_invite_and_create_join_request` RPC P0001 MESSAGE)
  /// to user-facing copy shown in the JoinRequestWaitingCard banner.
  private func friendlyInviteGoneMessage(for code: String) -> String {
    switch code {
    case "invite_not_found":
      return "This invite code doesn't exist. Check for typos or ask the admin for a new one."
    case "invite_deleted":
      return "This invite was deleted by the workspace admin. Ask them for a new one."
    case "invite_expired":
      return "This invite has expired. Ask the admin to generate a new one."
    case "invite_exhausted":
      return "This invite has reached its usage limit. Ask the admin for a new one."
    case "workspace_mismatch":
      return "This invite belongs to a different workspace."
    case "request_already_pending":
      return "You already have a pending request for this invite. Wait for the admin to approve it."
    default:
      return "This invite is no longer available. (\(code))"
    }
  }
}
