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
public enum FeedFilter: Hashable, Sendable, Codable {
    case all
    case directMessages
    case openTasks
    case decisions
    case blockers
    case shareSource(ShareSource)

    // MARK: - Codable (stable string key encoding for UserDefaults persistence)

    private enum CodingKeys: String, CodingKey {
        case kind
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "all":            self = .all
        case "directMessages": self = .directMessages
        case "openTasks":      self = .openTasks
        case "decisions":      self = .decisions
        case "blockers":       self = .blockers
        case "shareSource":
            let src = try container.decode(ShareSource.self, forKey: .source)
            self = .shareSource(src)
        default:
            // Forward-compat: unknown future cases fall back to .all.
            self = .all
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:            try container.encode("all",            forKey: .kind)
        case .directMessages: try container.encode("directMessages", forKey: .kind)
        case .openTasks:      try container.encode("openTasks",      forKey: .kind)
        case .decisions:      try container.encode("decisions",      forKey: .kind)
        case .blockers:       try container.encode("blockers",       forKey: .kind)
        case .shareSource(let src):
            try container.encode("shareSource", forKey: .kind)
            try container.encode(src,           forKey: .source)
        }
    }
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
