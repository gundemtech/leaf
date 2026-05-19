import Foundation
import Observation

/// Phase Track-5 S2 — observable state holder for the currently-active
/// workspace id. Backed by `UserDefaults` (key:
/// `leaf.active_workspace_id`). SwiftUI views subscribe via
/// `@Environment(ActiveWorkspaceStore.self)`. Non-UI processes (Agent,
/// MCPServer) read the same UserDefaults key directly via
/// `ActiveWorkspaceStore.userDefaultsKey`.
///
/// Post-M019 first launch: `backfillIfNeeded(database:)` resolves the
/// active id to the oldest workspace (created_at_ms ASC) if nothing is set.
/// Called once during composition root setup. Idempotent.
@MainActor
@Observable
public final class ActiveWorkspaceStore {
    /// `nonisolated` so non-UI processes (Agent, MCPServer) can read the
    /// `UserDefaults` key from off-MainActor contexts without bouncing to
    /// the MainActor first. Per the class doc-comment: this is a
    /// concurrency-immutable string constant — accessing it does not race
    /// with the @Observable instance state.
    public nonisolated static let userDefaultsKey = "leaf.active_workspace_id"

    public private(set) var activeWorkspaceID: String?

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.activeWorkspaceID = userDefaults.string(forKey: Self.userDefaultsKey)
    }

    /// Set the active workspace id. Persists to UserDefaults. Passing `nil`
    /// clears the key.
    public func setActive(_ id: String?) {
        activeWorkspaceID = id
        if let id {
            userDefaults.set(id, forKey: Self.userDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.userDefaultsKey)
        }
    }

    /// Resolve active workspace if currently nil. Picks the oldest workspace
    /// (ASC `created_at_ms`) excluding soft-marked-left rows. Idempotent —
    /// no-op if `activeWorkspaceID` is already set. Throws `Database` errors.
    public func backfillIfNeeded(database: Database) throws {
        guard activeWorkspaceID == nil else { return }
        let oldest = try database.listWorkspaces(includeLeft: false)
            .sorted { $0.createdAt < $1.createdAt }
            .first
        if let oldest {
            setActive(oldest.id)
        }
    }
}
