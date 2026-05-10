//
//  LeafBannerTokens.swift
//  Track 2 / D1 — T3 tokens for LeafBanner. Tone enum (info / success / warning
//  / danger) bundles bg + border + SF Symbol icon name. Tone is a deliberately
//  nested enum (rather than re-using LeafColor.status) because banners need
//  faint tinted backgrounds + bordered surfaces, which are derived from status
//  colors but not directly equivalent to any LeafColor token.
//

import SwiftUI

enum LeafBannerTokens {
    enum Tone {
        case info, success, warning, danger

        var bg: Color {
            switch self {
            case .info:    LeafColor.status.info.opacity(0.10)
            case .success: LeafColor.status.success.opacity(0.10)
            case .warning: LeafColor.status.warning.opacity(0.12)
            case .danger:  LeafColor.status.danger.opacity(0.10)
            }
        }

        var border: Color {
            switch self {
            case .info:    LeafColor.status.info
            case .success: LeafColor.status.success
            case .warning: LeafColor.status.warning
            case .danger:  LeafColor.status.danger
            }
        }

        /// Asset Catalog name (template-rendered) for the leading glyph.
        var icon: String {
            switch self {
            case .info:    LeafIcons.status.info
            case .success: LeafIcons.status.successFill
            case .warning: LeafIcons.status.warningFill
            case .danger:  LeafIcons.status.warningFill
            }
        }
    }

    static let borderOpacity: Double = 0.4
    static let cornerRadius: CGFloat = LeafRadius.md
    static let padding:      CGFloat = LeafSpace.md
}
