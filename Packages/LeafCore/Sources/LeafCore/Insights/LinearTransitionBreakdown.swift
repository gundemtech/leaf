import Foundation

/// Phase 4.6.B — counts of my status transitions in Linear over the period.
/// The producer (LinearCollector + ProdLinearGraphQLProvider) emits
/// `event_kind="status_transition"` events after fetching the history fragment
/// per issue (client-side filter actor.id == viewer.id). The aggregator groups
/// by `to_state_type` / `from_state_type` via mutually-exclusive priority.
///
/// Bucketing semantics:
/// - `started`   = `to_type=started AND from_type != completed` (a fresh activation
///   of an issue from backlog/unstarted/canceled).
/// - `completed` = `to_type=completed` (any landing in a Done state).
/// - `canceled`  = `to_type=canceled` (any landing in Cancelled).
/// - `reopened`  = `from_type=completed AND to_type != completed` (any undo of
///   completion — reopen into work, move to backlog/triage, cancel after Done).
///
/// `total = started + completed + canceled + reopened` — the sum may exceed the unique
/// transition count for `completed → canceled` (which falls into canceled AND reopened
/// at once: orthogonal "terminal cancellation" + "completion was undone"
/// signals).
public struct LinearTransitionBreakdown: Sendable, Hashable, Codable {
    public let started: Int
    public let completed: Int
    public let canceled: Int
    public let reopened: Int

    public var total: Int { started + completed + canceled + reopened }

    public init(started: Int, completed: Int, canceled: Int, reopened: Int) {
        self.started = started
        self.completed = completed
        self.canceled = canceled
        self.reopened = reopened
    }

    public static let empty = LinearTransitionBreakdown(
        started: 0, completed: 0, canceled: 0, reopened: 0
    )
}
