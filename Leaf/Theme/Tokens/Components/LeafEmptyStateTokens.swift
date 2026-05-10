//
//  LeafEmptyStateTokens.swift
//  Track 2 / D1 — T3 tokens for LeafEmptyState. Replaces the bare 56pt
//  outline glyph with a LeafIconChip xl (64pt squircle holding a 32pt
//  template glyph) so the visual reads as a contained placeholder, not
//  a gigantic floating icon. Per-segment vertical gaps replace uniform
//  stack spacing so the typographic rhythm is tighter near the chip and
//  more breathable above the CTA.
//

import SwiftUI

enum LeafEmptyStateTokens {
    static let chipSize:            LeafIconChipTokens.Size = .xl
    static let chipBackgroundOpacity: Double  = 0.10
    static let descriptionMaxWidth: CGFloat = 360
    static let verticalPadding:     CGFloat = LeafSpace.xxl

    /// Vertical gap between chip and title — tight so they read as one block.
    static let chipTitleGap:         CGFloat = LeafSpace.lg
    /// Title→description gap — title.medium has its own line spacing, so we
    /// only want a small breath here.
    static let titleDescriptionGap:  CGFloat = LeafSpace.xxs
    /// Description→CTA gap — slightly larger so the CTA reads as a separate
    /// affordance, not a continuation of body copy.
    static let descriptionCTAGap:    CGFloat = LeafSpace.lg

    /// Track 2 / D2 — minimum vertical region for full-page centered
    /// placement (HomeView .notConfigured / .empty fallbacks render the
    /// state as Spacer + LeafEmptyState + Spacer inside this min height).
    /// Keeps the empty surface from collapsing into a tight band when the
    /// scroll view's intrinsic height is small.
    static let centeredMinHeight:    CGFloat = 480
}
