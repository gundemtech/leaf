//
//  ClaudeCodeSurfaceCardViewModel.swift
//  Track 7 P1 — pure mapper from (AIToolsStore, InsightsSnapshot?) →
//  SurfaceCardState<ClaudeCodeCardPayload>. Namespace enum (not a class)
//  because the mapping is stateless — there's nothing to cache, no
//  async work, no Observation subscriptions to manage. SurfacesSection
//  calls `state(toolsStore:snapshot:)` per body pass; SwiftUI already
//  tracks both inputs via @Observable on AIToolsStore + the snapshot
//  parameter, so re-evaluation is automatic without us holding a class
//  instance.
//
//  P1 scope: this mapper does NOT surface real token / tool / session
//  counts. Aggregating those values requires a separate
//  `aiActivityBreakdown(period:)` query that's too expensive to run per
//  Home redraw and not exposed on InsightsSnapshot. The detail screen
//  (ClaudeCodeDetailViewModel, T10/T11) performs that query on demand.
//  Home card therefore flips between three visible states:
//  disabled / loading / "open for details".
//
//  P2-P6 surface VMs should follow the same namespace-enum + static
//  state(...) pattern unless they hold real cached state.
//

import Foundation
import LeafCore

enum ClaudeCodeSurfaceCardViewModel {
    /// Returns the card-render state for the current `(toolsStore, snapshot)`
    /// pair. Stateless: callers re-invoke per body pass and SwiftUI tracks
    /// inputs via @Observable on AIToolsStore + parameter change.
    static func state(
        toolsStore: AIToolsStore,
        snapshot: InsightsSnapshot?
    ) -> SurfaceCardState<ClaudeCodeCardPayload> {
        guard toolsStore.isEnabled("claude_code") else {
            return .disabled
        }
        guard snapshot != nil else {
            return .enabledLoading
        }
        // P1: no aggregate token / tool / session counts available on
        // InsightsSnapshot. Card renders the "zero today" treatment until
        // the detail screen is opened. Post-P1 carry-over: optionally
        // promote InsightsSnapshot to carry AIActivityBreakdown so card can
        // surface real headline numbers without re-running the SQL query.
        return .enabledZeroToday
    }
}
