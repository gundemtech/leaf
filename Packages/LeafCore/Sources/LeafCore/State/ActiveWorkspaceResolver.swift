import Foundation

/// Pure, `nonisolated`, Sendable result of resolving which workspace is active.
/// Used off the MainActor by `WorkspaceReader`'s detached loader (the
/// `@MainActor`-bound `ActiveWorkspaceStore` can't be touched there) and by
/// `ActiveWorkspaceStore.backfillIfNeeded` (single source of truth).
public struct ActiveResolution: Sendable, Equatable {
  /// The resolved active workspace, or `nil` when a non-nil `knownActiveID`
  /// does not exist in `workspaces` (caller surfaces an "unresolved" error).
  public let active: Workspace?
  /// Non-nil when `knownActiveID` was `nil` and we picked the oldest workspace:
  /// the caller must persist it via `ActiveWorkspaceStore.setActive` on the MainActor.
  public let backfilledID: String?

  public init(active: Workspace?, backfilledID: String?) {
    self.active = active
    self.backfilledID = backfilledID
  }
}

/// Resolve the active workspace from a pre-filtered list (caller passes
/// `listWorkspaces(includeLeft: false)`, so left/deleted rows are already gone).
///
/// - `knownActiveID` present in `workspaces` → that workspace, no backfill.
/// - `knownActiveID` nil → oldest by `createdAt` ASC (the backfill rule),
///   reported via `backfilledID` so the caller persists it.
/// - `knownActiveID` set but absent → `active == nil` (caller emits error).
/// - empty list → `active == nil`, no backfill.
public func resolveActiveWorkspace(
  _ workspaces: [Workspace], knownActiveID: String?
) -> ActiveResolution {
  if let knownActiveID {
    return ActiveResolution(
      active: workspaces.first { $0.id == knownActiveID },
      backfilledID: nil
    )
  }
  let oldest = workspaces.sorted { $0.createdAt < $1.createdAt }.first
  return ActiveResolution(active: oldest, backfilledID: oldest?.id)
}
