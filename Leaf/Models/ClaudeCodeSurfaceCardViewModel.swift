//
//  ClaudeCodeSurfaceCardViewModel.swift
//  Track 7 P1 — derives SurfaceCardState<ClaudeCodeCardPayload> from
//  AIToolsStore toggle + InsightsReader snapshot presence. Stateless —
//  SurfacesSection calls `state(snapshot:)` per body pass; SwiftUI re-runs
//  body on either store change or snapshot change.
//
//  P1 scope: VM does NOT surface real token / tool / session counts.
//  Aggregating those values requires a separate `aiActivityBreakdown(period:)`
//  query that's too expensive to run per Home redraw and not exposed on
//  InsightsSnapshot. The detail screen (ClaudeCodeDetailViewModel, T10/T11)
//  performs that query on demand. Home card therefore flips between three
//  visible states: disabled / loading / "open for details".
//

import Foundation
import Observation
import LeafCore

@MainActor
@Observable
final class ClaudeCodeSurfaceCardViewModel {
    private let toolsStore: AIToolsStore

    init(toolsStore: AIToolsStore) {
        self.toolsStore = toolsStore
    }

    /// Returns the card-render state for the current `(toolsStore, snapshot)`
    /// pair. Stateless: callers re-invoke per body pass and SwiftUI tracks
    /// both inputs via @Observable.
    func state(snapshot: InsightsSnapshot?) -> SurfaceCardState<ClaudeCodeCardPayload> {
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
