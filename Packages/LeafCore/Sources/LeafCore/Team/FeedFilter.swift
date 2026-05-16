//
//  FeedFilter.swift
//  Track 5 / S7 B.6 — FeedFilter enum for TeamFeed chip multi-select.
//  Used by LeafFilterChips atom and TeamFeedReader (Phase C).
//

import Foundation

/// Coarse-grain filter for the Team feed. Drives the LeafFilterChips horizontal
/// pill row. Selection rules (per spec §4.5):
///   • `.all` is mutually exclusive — selecting it clears all others.
///   • Selecting any other filter deselects `.all` automatically.
///   • If the last non-`.all` filter is deselected the set restores to `[.all]`.
public enum FeedFilter: Hashable, Sendable {
    case all
    case directMessages
    case openTasks
    case decisions
    case blockers
    case shareSource(ShareSource)
}

public extension FeedFilter {

    /// Display label for chip pill and popover toggle row.
    ///
    /// NOTE: `.decisions` / `.blockers` use "My Decisions" / "My Blockers" to
    /// avoid collision with `ShareSource.detectedDecisions` / `.detectedBlockers`
    /// ("Decisions" / "Blockers") in the uniqueness invariant required by
    /// `LeafFilterChips` (spec §4.5 — each label must be distinct so VoiceOver
    /// and tap-target disambiguation work correctly).
    var displayLabel: String {
        switch self {
        case .all:              return "All"
        case .directMessages:   return "Direct Messages"
        case .openTasks:        return "Open Tasks"
        case .decisions:        return "My Decisions"
        case .blockers:         return "My Blockers"
        case .shareSource(let src): return src.displayName
        }
    }

    /// True iff this filter is mutually exclusive with all others.
    /// Only `.all` is exclusive — selecting it collapses the entire selection.
    var isExclusive: Bool {
        if case .all = self { return true }
        return false
    }
}
