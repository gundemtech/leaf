//
//  LeafFilterChipsTokens.swift
//  Track 5 / S7 B.6 — T3 component tokens for LeafFilterChips.
//

import CoreGraphics

enum LeafFilterChipsTokens {
    /// Horizontal spacing between adjacent pill chips.
    static let chipSpacing: CGFloat = LeafSpace.xs

    /// Minimum width of the "More…" popover panel.
    static let popoverMinWidth: CGFloat = 240

    /// Padding inside the popover panel (all edges).
    static let popoverPadding: CGFloat = LeafSpace.md

    /// Fixed row height for each toggle row inside the popover.
    static let popoverRowHeight: CGFloat = 32
}
