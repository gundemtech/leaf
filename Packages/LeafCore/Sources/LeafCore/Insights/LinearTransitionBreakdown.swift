import Foundation

/// Phase 4.6.B — counts моих status transitions в Linear за period.
/// Producer (LinearCollector + ProdLinearGraphQLProvider) эмитит
/// `event_kind="status_transition"` events после fetch'а history fragment'а
/// per issue (client-side filter actor.id == viewer.id). Aggregator группирует
/// по `to_state_type` / `from_state_type` через mutually-exclusive priority.
///
/// Bucketing semantics:
/// - `started`   = `to_type=started AND from_type != completed` (новая активация
///   issue из backlog/unstarted/canceled).
/// - `completed` = `to_type=completed` (любое попадание в Done state).
/// - `canceled`  = `to_type=canceled` (любое попадание в Cancelled).
/// - `reopened`  = `from_type=completed AND to_type != completed` (любое отмена
///   завершения — reopen в work, перенос в backlog/triage, cancel after Done).
///
/// `total = started + completed + canceled + reopened` — sum может exceed unique
/// transition count для `completed → canceled` (попадает в canceled И reopened
/// одновременно: orthogonal "terminal cancellation" + "completion was undone"
/// сигналы).
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

    public static let empty = Self(
        started: 0, completed: 0, canceled: 0, reopened: 0
    )
}
