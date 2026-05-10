//
//  LeafIconChipTokens.swift
//  Track 2 / D1 — T3 tokens for LeafIconChip. Squircle container that holds
//  a tone-tinted glyph; reused by banners (leading slot), notifications,
//  and any list-row affordance that needs a tinted icon presence rather
//  than a free-floating glyph on the surface.
//

import SwiftUI

enum LeafIconChipTokens {
    enum Size {
        case sm, md, lg, xl

        /// Outer container dimension (square). xl is the empty-state hero
        /// scale — large enough to anchor a centered surface without the
        /// "gigantic naked glyph" look of a bare 56pt outline.
        var outer: CGFloat {
            switch self {
            case .sm: 24
            case .md: 32
            case .lg: 40
            case .xl: 64
            }
        }

        /// Inner icon size — pairs with LeafIconSize so the glyph weight
        /// matches the rest of the system at each scale.
        var icon: LeafIconSize {
            switch self {
            case .sm: .sm
            case .md: .md
            case .lg: .lg
            case .xl: .xl
            }
        }

        /// Squircle corner radius — biased toward LeafRadius so chips align
        /// with surrounding rounded surfaces at the same scale.
        var cornerRadius: CGFloat {
            switch self {
            case .sm: LeafRadius.sm
            case .md: LeafRadius.md
            case .lg: LeafRadius.lg
            case .xl: LeafRadius.xl
            }
        }
    }

    /// Default background opacity when the consumer passes only a tint —
    /// produces a faint tone wash that reads as a chip without competing
    /// with surrounding content.
    static let defaultBackgroundOpacity: Double = 0.15
}
