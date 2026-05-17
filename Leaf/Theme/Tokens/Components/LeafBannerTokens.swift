//
//  LeafBannerTokens.swift
//  Track 2 / D1 — T3 tokens for LeafBanner. Tone enum (info / success /
//  warning / danger) maps to a chip tint + leading glyph. The banner itself
//  sits on a neutral raised surface — only the LeafIconChip carries tone,
//  which keeps the banner from reading like a flat-tinted sticker and lets
//  multiple stacked banners coexist without competing for attention.
//

import SwiftUI

enum LeafBannerTokens {
    enum Tone {
        case info, success, warning, danger

        /// Color used for the leading chip's glyph + (at default opacity) its
        /// background tint. The banner surface itself stays neutral.
        var tint: Color {
            switch self {
            case .info: LeafColor.status.info
            case .success: LeafColor.status.success
            case .warning: LeafColor.status.warning
            case .danger: LeafColor.status.danger
            }
        }

        /// Asset Catalog name (template-rendered) for the leading glyph.
        var icon: String {
            switch self {
            case .info: LeafIcons.status.info
            case .success: LeafIcons.status.successFill
            case .warning: LeafIcons.status.warningFill
            case .danger: LeafIcons.status.warningFill
            }
        }
    }

    static let cornerRadius: CGFloat = LeafRadius.lg
    static let padding: CGFloat = LeafSpace.lg
    static let chipSize: LeafIconChipTokens.Size = .md
    static let titleDescriptionGap: CGFloat = LeafSpace.xxs
    static let bodyCTAGap: CGFloat = LeafSpace.sm
}
