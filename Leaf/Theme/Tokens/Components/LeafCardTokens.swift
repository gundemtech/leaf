//
//  LeafCardTokens.swift
//  Track 2 / D1 — T3 tokens for LeafCard. Variants rest/raised/glass and
//  padding presets tight/regular/generous (mapped onto LeafSpace scale).
//

import CoreGraphics

enum LeafCardTokens {
    enum Variant {
        case rest
        case raised
        case glass
    }

    enum PaddingPreset {
        case tight, regular, generous

        var pt: CGFloat {
            switch self {
            case .tight:    return LeafSpace.md
            case .regular:  return LeafSpace.lg
            case .generous: return LeafSpace.xl
            }
        }
    }
}
