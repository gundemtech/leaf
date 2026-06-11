//
//  AccountDeletionService.swift
//  LeafCore
//
//  Orchestrates account deletion: SERVER delete first, then the local teardown
//  — only if the server delete succeeded (a failed server call must never
//  half-wipe the device). Closure-injected so it carries no app-type
//  dependency and is unit-testable with spies.
//
//  Local teardown scope (this phase) is security-complete: clear session +
//  unregister launch agent (signOut), drop the device identity key
//  (deleteIdentity). Full on-disk DB/keystore shred is a deferred follow-up
//  (needs Agent-process lifecycle coordination — see spec §4.3).
//

import Foundation

public struct AccountDeletionService: Sendable {
  private let deleteAccount: @Sendable () async throws -> Void
  private let signOut: @Sendable () async -> Void
  private let deleteIdentity: @Sendable () throws -> Void

  public init(
    deleteAccount: @escaping @Sendable () async throws -> Void,
    signOut: @escaping @Sendable () async -> Void,
    deleteIdentity: @escaping @Sendable () throws -> Void
  ) {
    self.deleteAccount = deleteAccount
    self.signOut = signOut
    self.deleteIdentity = deleteIdentity
  }

  /// Delete the account server-side, then (only on success) run the local
  /// teardown. Rethrows the server error without touching local state.
  public func run() async throws {
    try await deleteAccount()  // server — must succeed first
    await signOut()  // clear session + unregister launch agent
    try deleteIdentity()  // drop the device X25519 private key
  }
}
