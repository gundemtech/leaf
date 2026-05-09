//
//  LeafAvatarTokens.swift
//  Track 2 / D1 — T3 tokens for LeafAvatar. Sizes sm(24)/md(36)/lg(56), font
//  scales with size. Status ring tint via LeafDotTone.
//

import SwiftUI

enum LeafAvatarTokens {
    enum Size {
        case sm, md, lg

        var pt: CGFloat {
            switch self {
            case .sm: return 24
            case .md: return 36
            case .lg: return 56
            }
        }

        var font: Font {
            switch self {
            case .sm: return LeafType.body.small
            case .md: return LeafType.body.regular
            case .lg: return LeafType.title.medium
            }
        }
    }
}
