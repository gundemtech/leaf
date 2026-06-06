import Foundation

/// Persists the invitee's OWN pending join-request IDs so an admin-approved
/// invite can be materialised even after the `JoinRequestWaitingCard` poll loop
/// dies (card dismissed, app quit/relaunched). Without this, materialisation is
/// gated entirely on the ephemeral in-memory card poll: if the invitee isn't
/// sitting on the open card when the admin approves, the approved+sealed
/// `join_requests` row is stranded forever (no local mirror, no resume).
///
/// An ID is added on submit and removed once its request reaches a terminal
/// state (joined / declined / cancelled / expired / vanished). On launch the
/// reader re-fetches each stored ID and materialises any that are `.approved`.
///
/// Backed by `UserDefaults` (JSON `[String]` under `leaf.pending_join_request_ids`),
/// mirroring `ActiveWorkspaceStore`. Request IDs are non-sensitive UUIDs, so
/// plaintext UserDefaults is appropriate (no SQLCipher needed).
// `@unchecked Sendable`: the struct is immutable and its only stored property,
// `UserDefaults`, is documented thread-safe — Apple just hasn't marked it Sendable.
public struct PendingJoinRequestStore: @unchecked Sendable {
  public nonisolated static let userDefaultsKey = "leaf.pending_join_request_ids"

  private let userDefaults: UserDefaults

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  /// All currently-pending request IDs, in insertion order.
  public func all() -> [String] {
    guard let data = userDefaults.data(forKey: Self.userDefaultsKey),
      let ids = try? JSONDecoder().decode([String].self, from: data)
    else { return [] }
    return ids
  }

  /// Append a request ID if not already present (idempotent).
  public func add(_ requestID: String) {
    var ids = all()
    guard !ids.contains(requestID) else { return }
    ids.append(requestID)
    persist(ids)
  }

  /// Drop a request ID (no-op if absent).
  public func remove(_ requestID: String) {
    var ids = all()
    guard ids.contains(requestID) else { return }
    ids.removeAll { $0 == requestID }
    persist(ids)
  }

  private func persist(_ ids: [String]) {
    if ids.isEmpty {
      userDefaults.removeObject(forKey: Self.userDefaultsKey)
    } else if let data = try? JSONEncoder().encode(ids) {
      userDefaults.set(data, forKey: Self.userDefaultsKey)
    }
  }
}
