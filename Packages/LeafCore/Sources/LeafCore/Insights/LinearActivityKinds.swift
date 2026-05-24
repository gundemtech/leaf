import Foundation

/// Track-10 T8 — single source of truth for the 4 Linear `status_transition`
/// `event_kind` discriminators emitted by `ProdInsights+RecentActivityFeed`.
/// Hoisted from `SinceLastActiveItem.verbMap` (Track-10 T5) so callers
/// downstream of `recentActivityFeed` (e.g. `StandupComposer`) can match
/// against a constant rather than a string literal — eliminates future
/// drift when the discriminator format evolves.
///
/// Values verified against the already-public `SinceLastActiveItem.verbMap`
/// keys (lines 80-83 pre-T8). Migrating that callsite to read from this
/// namespace in the same commit guarantees no string duplication.
public enum LinearActivityKinds {
    public static let statusTransitionStartedKind = "linear_status_transition.started"
    public static let statusTransitionCompletedKind = "linear_status_transition.completed"
    public static let statusTransitionCanceledKind = "linear_status_transition.canceled"
    public static let statusTransitionReopenedKind = "linear_status_transition.reopened"
}
