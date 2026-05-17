//
//  LeafCardTokens.swift
//  Track 2 / D1 — T3 tokens for LeafCard. Variants rest/raised/glass and
//  padding presets tight/regular/generous (mapped onto LeafSpace scale).
//  Adds hairline border + per-slot vertical gaps so the chrome reads as
//  a defined surface on any background, not a floating text block.
//

import SwiftUI

enum LeafCardTokens {
    enum Variant {
        case rest
        case raised
        case glass

        /// Elevation applied to the variant's outer surface. Rest is flat —
        /// the card's job is grouping, not lifting. Raised uses floating so
        /// it reads as a card on top of any surface (incl. surface.raised).
        /// Glass uses raised since the material itself carries depth.
        var elevation: LeafElevation.Shadow {
            switch self {
            case .rest: LeafElevation.flat
            case .raised: LeafElevation.floating
            case .glass: LeafElevation.raised
            }
        }
    }

    enum PaddingPreset {
        case tight, regular, generous

        var pt: CGFloat {
            switch self {
            case .tight: LeafSpace.md
            case .regular: LeafSpace.lg
            case .generous: LeafSpace.xl
            }
        }
    }

    static let cornerRadius: CGFloat = LeafRadius.lg
    static let borderColor: Color = LeafColor.border.subtle
    static let borderWidth: CGFloat = 1

    /// Vertical gap between header slot and content slot.
    static let headerContentGap: CGFloat = LeafSpace.sm
    /// Vertical gap between content slot and footer slot.
    static let contentFooterGap: CGFloat = LeafSpace.lg
}
