//
//  AttachmentProvider.swift
//  LeafCore
//
//  Track 5 / S7 B.7 — Identifies which external provider an attachment came from.
//  Used by LeafLinkedEventCard and attachment readers to route icons and links.
//

/// The external provider that originated an attachment.
public enum AttachmentProvider: String, Codable, Sendable, Hashable {
    case github
    case linear
    case slack
}
