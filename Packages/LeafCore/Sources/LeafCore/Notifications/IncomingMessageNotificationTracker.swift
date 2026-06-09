import Foundation

/// Dedup + first-poll-batch suppression for incoming-DM local notifications.
///
/// Owned by `DirectMessageInboxReader` (app target, @MainActor, no unit-test
/// bundle) so the logic stays testable in LeafCore. No timestamps / clocks /
/// persistence — dedup is by `messageID` (exact), which avoids the clock-skew
/// and same-millisecond bugs a `serverCreatedAtMs` watermark would have.
///
/// Two delivery paths share one notified-id set:
///   - **Realtime**: Supabase POSTGRES_CHANGES never replays history on subscribe,
///     so every inbound row is a live post-subscription event → notify unless the
///     id was already seen.
///   - **Polling**: the FIRST batch per workspace per session is backlog (history
///     on fresh install, or messages that arrived while the app was closed) →
///     suppressed and recorded; subsequent batches notify new ids. In-memory, so
///     a restart re-primes and re-suppresses the backlog — the desired "don't
///     re-notify unread backlog on relaunch" behaviour.
public struct IncomingMessageNotificationTracker {
  private var notifiedMessageIDs: Set<String> = []
  private var polledWorkspaces: Set<String> = []

  public init() {}

  /// Realtime delivery. Returns `true` once per `messageID` (records it).
  public mutating func shouldNotifyRealtime(messageID: String) -> Bool {
    guard !notifiedMessageIDs.contains(messageID) else { return false }
    notifiedMessageIDs.insert(messageID)
    return true
  }

  /// Polling delivery of a batch for `workspaceID`. The first batch per workspace
  /// is suppressed (backlog) and its ids recorded so a later realtime/poll won't
  /// re-notify them; subsequent batches return the new, deduped ids in order.
  public mutating func notifiablePolledMessageIDs(
    workspaceID: String, messageIDs: [String]
  ) -> [String] {
    guard polledWorkspaces.contains(workspaceID) else {
      polledWorkspaces.insert(workspaceID)
      notifiedMessageIDs.formUnion(messageIDs)
      return []
    }
    var out: [String] = []
    for id in messageIDs where !notifiedMessageIDs.contains(id) {
      notifiedMessageIDs.insert(id)
      out.append(id)
    }
    return out
  }
}
