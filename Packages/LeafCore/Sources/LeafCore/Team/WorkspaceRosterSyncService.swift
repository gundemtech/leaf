//
//  WorkspaceRosterSyncService.swift
//  LeafCore
//
//  Roster read-back: fetch the full server `workspace_members` list and
//  reconcile it into the local `team_members` table. Closes the asymmetric-
//  roster gap where invitees only ever saw {admin, self} (built from direct
//  observation) and never each other — the server roster was written by every
//  member but never read back. RLS `workspace_members_peer_read` already lets
//  any member read the whole workspace roster, so this is a client-only fix.
//
//  Idempotent: insert-if-absent by pubkey (never resurrects a removed member,
//  never overwrites an existing row's role/name). Reconciled members default to
//  `.member` (the server roster carries no role; the admin row is already local
//  with the correct role and is left untouched by the absent-only insert).
//

import Foundation

public struct WorkspaceRosterSyncService: Sendable {
  private let database: Database
  private let supabase: SupabaseClient
  private let now: @Sendable () -> Date

  public init(
    database: Database,
    supabase: SupabaseClient,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.database = database
    self.supabase = supabase
    self.now = now
  }

  /// Fetch the server roster and insert any members not already present locally
  /// (matched by pubkey, case-insensitive). Returns the number of newly-added
  /// members so the caller can decide whether to refresh the UI.
  @discardableResult
  public func sync(workspaceID: String) async throws -> Int {
    let remote = try await supabase.fetchWorkspaceMembers(workspaceID: workspaceID)
    // Compare against ALL local rows (incl. removed) so a previously-removed
    // member isn't resurrected as active by a stale server roster row.
    let existing = Set(
      try database.readTeamMembers(workspaceID: workspaceID, includeRemoved: true)
        .map { $0.pubkeyHex.lowercased() })

    var added = 0
    for member in remote {
      let pubkey = member.pubkeyHex.lowercased()
      guard !existing.contains(pubkey) else { continue }
      try database.insertTeamMemberIfAbsent(
        TeamMember(
          id: UUID().uuidString.lowercased(),
          workspaceID: workspaceID,
          role: .member,
          pubkeyHex: pubkey,
          displayName: member.displayName,
          addedAt: now(),
          removedAt: nil
        ))
      added += 1
    }
    return added
  }
}
