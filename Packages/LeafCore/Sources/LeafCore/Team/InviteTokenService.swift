//
//  InviteTokenService.swift
//  LeafCore
//
//  M027 invite-redesign — admin-side generation / listing / deletion of
//  workspace invite tokens. NO crypto — token is a pure identifier (the
//  workspace teamKey is sealed at admin's `Approve` moment on the
//  corresponding join_request row; see `JoinRequestService.approve`).
//
//  Architecture: server-first writes (Supabase RLS enforces admin scope +
//  unique code constraint), then local mirror UPSERT. If server rejects, local
//  stays untouched; if local fails after server success, refreshFromServer
//  reconciles on next workspace open.
//

import Foundation

public struct InviteTokenService: Sendable {
  private let database: Database
  private let supabase: SupabaseClient
  private let workspaceID: String
  private let createdByPubkeyHex: String
  private let now: @Sendable () -> Date

  public init(
    database: Database,
    supabase: SupabaseClient,
    workspaceID: String,
    createdByPubkeyHex: String,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.database = database
    self.supabase = supabase
    self.workspaceID = workspaceID
    self.createdByPubkeyHex = createdByPubkeyHex
    self.now = now
  }

  // MARK: - Generate

  /// Generate a new invite token. Picks a fresh `JoinCode.generateRandom()`,
  /// applies TTL (0 sentinel = «Never expires»), single-use flag, POSTs to
  /// Supabase, then mirrors locally with the server's authoritative
  /// `created_at`. Throws `InviteTokenError.maxActiveTokensReached` if the
  /// workspace already has 10 active tokens (per spec §7).
  ///
  /// - Parameters:
  ///   - label: optional human label (max length not enforced here; UI caps it).
  ///   - ttlSeconds: TTL in seconds OR 0 for «Never expires».
  ///   - singleUse: true → `max_uses = 1`; false → unlimited.
  @discardableResult
  public func generate(
    label: String?,
    ttlSeconds: Int,
    singleUse: Bool
  ) async throws -> InviteToken {
    let nowDate = now()
    // Pre-flight cap check (cheap read).
    let active = try database.countActiveInviteTokens(workspaceID: workspaceID, now: nowDate)
    guard active < InviteTokenStore.maxActiveTokensPerWorkspace else {
      throw InviteTokenError.maxActiveTokensReached
    }

    let code = try JoinCode.generateRandom()
    let expiresAt: Date? =
      ttlSeconds > 0
      ? nowDate.addingTimeInterval(TimeInterval(ttlSeconds))
      : nil
    let candidate = InviteToken(
      code: code,
      workspaceID: workspaceID,
      createdByPubkeyHex: createdByPubkeyHex,
      label: (label?.isEmpty ?? true) ? nil : label,
      ttlSeconds: ttlSeconds,
      expiresAt: expiresAt,
      maxUses: singleUse ? 1 : nil,
      usedCount: 0,
      deletedAt: nil,
      createdAt: nowDate
    )

    // Server first — Supabase RLS enforces admin scope + WITH CHECK enforces
    // created_by_pubkey == JWT pubkey claim.
    let serverEcho = try await supabase.insertInviteToken(candidate)
    // Mirror locally; cap is re-checked under transaction for race safety.
    try database.insertInviteTokenCappedAtMaxActive(serverEcho, now: nowDate)
    return serverEcho
  }

  // MARK: - List / fetch

  public func listActive() throws -> [InviteToken] {
    try database.listActiveInviteTokens(workspaceID: workspaceID, now: now())
  }

  public func listAll() throws -> [InviteToken] {
    try database.listAllInviteTokens(workspaceID: workspaceID)
  }

  public func fetch(code: String) throws -> InviteToken? {
    try database.fetchInviteToken(code: code)
  }

  // MARK: - Delete (soft)

  /// Soft-delete a token. Local mirror commits first; server PATCH follows
  /// best-effort. Mirrors the discipline used by `WorkspaceReader.delete`
  /// after dogfooding round 5 — server-first ordering caused
  /// `Content-Range: */0 → .noRowsAffected` from PostgREST (legacy tokens
  /// the server never knew about, or cron-swept rows the client still
  /// believed in) to throw BEFORE the local UPDATE, so ActiveTokensSection
  /// kept resurrecting the same «deleted» token on every refresh and the
  /// user couldn't escape the loop. Idempotent: re-deleting already-deleted
  /// token rewrites `deleted_at` to current timestamp on both sides.
  public func delete(code: String) async throws {
    try database.markInviteTokenDeleted(code: code, at: now())
    do {
      try await supabase.markInviteTokenDeleted(code: code)
    } catch SupabaseError.noRowsAffected {
      // Server row already gone (cron sweep, or token never reached
      // server because admin's workspace pre-dates `insertWorkspace`).
      // Local mirror already committed; convergent state.
    }
    // Other Supabase errors propagate — caller surfaces them. Local
    // commit stands; next refreshFromServer reconciles if needed.
  }

  // MARK: - Refresh

  /// Reconcile local mirror against server state. Called on workspace open
  /// and after any UI-driven mutation that touched server state. UPSERTs each
  /// row from server; rows present locally but not on server stay locally
  /// (best-effort cache — server is source of truth but we don't aggressively
  /// purge to avoid race with concurrent generate paths).
  @discardableResult
  public func refreshFromServer() async throws -> Int {
    let server = try await supabase.listInviteTokens(workspaceID: workspaceID)
    for token in server {
      try? database.upsertInviteToken(token)
    }
    return server.count
  }
}
