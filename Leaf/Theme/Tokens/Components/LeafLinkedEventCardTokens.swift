//
//  LeafLinkedEventCardTokens.swift
//  Track 5 / S7 B.7 — T3 tokens for LeafLinkedEventCard.
//  Full variant: raised card with provider icon + title + status pill + meta line.
//  Compact variant: inline icon + ref label + chevron (no card chrome).
//

import CoreGraphics

enum LeafLinkedEventCardTokens {
    /// Inner padding for the full (raised-card) variant.
    static let fullCardPadding:  CGFloat = LeafSpace.sm

    /// Width and height of the provider icon in both variants.
    static let providerIconSize: CGFloat = 18

    /// Horizontal gap between icon and ref label in compact variant.
    static let compactSpacing:   CGFloat = LeafSpace.xs

    /// Max lines for the attachment title in the full variant.
    /// 2-line cap keeps cards uniform height in feeds.
    static let titleLineLimit:   Int     = 2
}
