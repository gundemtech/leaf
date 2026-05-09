//
//  LeafEmptyStateTokens.swift
//  Track 2 / D1 — T3 tokens for LeafEmptyState. Centralises the icon size
//  (56pt large SF Symbol per spec — "no mascots"), description max width, and
//  vertical padding so empty states across surfaces stay visually consistent
//  without forking the component.
//

import CoreGraphics

enum LeafEmptyStateTokens {
    static let iconSize:            CGFloat = 56
    static let descriptionMaxWidth: CGFloat = 360
    static let verticalPadding:     CGFloat = LeafSpace.xxl
    static let stackSpacing:        CGFloat = LeafSpace.md
    static let ctaTopPadding:       CGFloat = LeafSpace.sm
}
