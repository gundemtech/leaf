//
//  TeamFeedItem.swift
//  LeafCore
//
//  Track 5 / S7 C.1 + C.2 — Unified feed item enum merging DMs and team events.
//  Consumed by TeamFeedQueryService (C.3) and TeamFeedReader (Leaf app target).
//
//  Grouping (the `.grouped` case) is produced by TeamFeedReader.applyGrouping (C.5),
//  NOT by the query service. The query service returns only .directMessage and
//  .teamEvent; grouping is a presentation-layer transform that requires
//  TeamMember resolution.
//

import Foundation

/// A single item in the unified Team feed. Three cases:
///   • `.directMessage` — a DM from the local mirror (messages_mirror).
///   • `.teamEvent` — a broadcast team event from the mirror (team_events_mirror).
///   • `.grouped` — N consecutive events from the same sender / source, collapsed
///     for density (produced by `TeamFeedReader.applyGrouping`, not the query layer).
public enum FeedItem: Identifiable, Equatable, Sendable {

    case directMessage(DirectMessageMirrorRow)
    case teamEvent(TeamEventMirrorRow)
    case grouped(
        kind: ShareSource,
        sender: TeamMember,
        count: Int,
        spanStartMs: Int64,
        spanEndMs: Int64,
        items: [TeamEventMirrorRow]
    )

    // MARK: - Identifiable

    /// Stable identity across re-fetches:
    ///   • `.directMessage` → messages_mirror PK (`message_id`)
    ///   • `.teamEvent`     → team_events_mirror composite key part (`event_id`)
    ///   • `.grouped`       → synthetic "grouped-<source_kind>-<sender_pubkey>-<spanStartMs>"
    ///
    /// DMs and events use UUIDs from different Supabase namespaces — collision is
    /// impossible in practice. The grouped prefix is unambiguous because UUIDs
    /// never start with "grouped-".
    public var id: String {
        switch self {
        case .directMessage(let row):
            return row.messageID
        case .teamEvent(let row):
            return row.eventID
        case .grouped(let kind, let sender, _, let spanStartMs, _, _):
            return "grouped-\(kind.rawValue)-\(sender.pubkeyHex)-\(spanStartMs)"
        }
    }

    // MARK: - Timestamp (for sort / pagination)

    /// The canonical sort timestamp for this item. Used by pagination cursor.
    ///   • `.directMessage` → `serverCreatedAtMs` (authoritative Supabase clock)
    ///   • `.teamEvent`     → `serverCreatedAtMs` (authoritative Supabase clock)
    ///   • `.grouped`       → `spanEndMs` (newest item in the group; keeps group
    ///     in its "most recent" position in the sorted feed)
    public var timestamp: Int64 {
        switch self {
        case .directMessage(let row):
            return row.serverCreatedAtMs
        case .teamEvent(let row):
            return row.serverCreatedAtMs
        case .grouped(_, _, _, _, let spanEndMs, _):
            return spanEndMs
        }
    }
}
