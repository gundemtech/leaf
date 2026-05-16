//
//  AttachmentMetadata.swift
//  LeafCore
//
//  Track 5 / S7 B.7 — Rich metadata for an external attachment (GitHub PR,
//  Linear issue, Slack thread). Consumed by LeafLinkedEventCard for the full
//  variant. Nil fields indicate loading state.
//
//  Codable: stored in messages_mirror.payload_json via CrossPostLogRow
//  and fetched from provider APIs in Phase C readers.
//

import Foundation

/// Semantic colour hint for a status label rendered by LeafLinkedEventCard.
/// Consumers map this to `LeafPillTokens.Tone`; the mapping lives in the UI
/// layer so LeafCore stays SwiftUI-free.
public enum StatusColorKey: String, Codable, Sendable, Hashable {
    case open
    case closed
    case merged
    case inProgress
    case completed
    case blocked
    case neutral
}

/// Display-ready metadata for an attachment link.
///
/// `statusLabel` and `statusColorKey` are always set together: if one is
/// present the other is too. A nil `statusLabel` signals the card should
/// render a loading skeleton rather than status chrome.
public struct AttachmentMetadata: Codable, Sendable, Hashable {

    /// Human-readable title — PR title, Linear issue title, Slack thread subject.
    public let title: String

    /// Short status label displayed inside a pill chip.
    /// Examples: "open", "merged", "In Progress", "Done".
    /// Nil when metadata is not yet loaded.
    public let statusLabel: String?

    /// Token key driving the pill's colour — decoupled from raw `Color` so
    /// LeafCore remains SwiftUI-free.
    public let statusColorKey: StatusColorKey

    /// Author or assignee display name shown in the compact meta line.
    public let authorDisplayName: String

    /// Unix epoch milliseconds — used for relative-timestamp formatting.
    public let createdAtMs: Int64

    /// Deep-link to the attachment on the provider's web interface.
    public let externalURL: URL

    public init(
        title: String,
        statusLabel: String?,
        statusColorKey: StatusColorKey,
        authorDisplayName: String,
        createdAtMs: Int64,
        externalURL: URL
    ) {
        self.title = title
        self.statusLabel = statusLabel
        self.statusColorKey = statusColorKey
        self.authorDisplayName = authorDisplayName
        self.createdAtMs = createdAtMs
        self.externalURL = externalURL
    }
}
