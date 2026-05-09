//
//  LeafInputTokens.swift
//  Track 2 / D1 — T3 tokens for LeafInput. Heights md=36 / lg=44; horizontal
//  padding LeafSpace.md; corner radius LeafRadius.md.
//

import CoreGraphics

enum LeafInputTokens {
    enum Size {
        case md, lg

        var height: CGFloat {
            switch self {
            case .md: return 36
            case .lg: return 44
            }
        }

        var horizontalPadding: CGFloat { LeafSpace.md }
        var cornerRadius:      CGFloat { LeafRadius.md }
    }
}
