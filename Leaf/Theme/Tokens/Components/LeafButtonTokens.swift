//
//  LeafButtonTokens.swift
//  Track 2 / D1 — T3 tokens for LeafButton (and shared by LeafIconButton).
//  Resolves variant + size to concrete LeafColor / LeafSpace / LeafType / LeafRadius.
//

import SwiftUI

enum LeafButtonTokens {
    enum Variant { case primary, secondary, ghost, destructive }

    enum Size {
        case sm, md, lg

        var height: CGFloat {
            switch self {
            case .sm: 28
            case .md: 36
            case .lg: 44
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .sm: LeafSpace.md
            case .md: LeafSpace.lg
            case .lg: LeafSpace.xl
            }
        }

        var font: Font {
            switch self {
            case .sm: LeafType.body.small
            case .md: LeafType.body.regular
            case .lg: LeafType.body.large
            }
        }

        var cornerRadius: CGFloat { LeafRadius.md }

        /// Icon point size matched to the size's font cap-height — used by
        /// LeafButton's asset render path so custom SVG icons read at the
        /// same visual weight as the surrounding label text.
        var iconPt: CGFloat {
            switch self {
            case .sm: 13   // body.small
            case .md: 15   // body.regular
            case .lg: 17   // body.large
            }
        }
    }

    enum Background {
        static func resting(_ variant: Variant) -> Color {
            switch variant {
            case .primary:     LeafColor.accent.primary
            case .secondary:   LeafColor.surface.raised
            case .ghost:       Color.clear
            case .destructive: LeafColor.status.danger
            }
        }

        static func hover(_ variant: Variant) -> Color {
            switch variant {
            case .primary:     LeafColor.accent.emphasis
            case .secondary:   LeafColor.surface.inset
            case .ghost:       LeafColor.surface.raised
            case .destructive: LeafColor.status.danger.opacity(0.85)
            }
        }
    }

    enum Foreground {
        static func resting(_ variant: Variant) -> Color {
            switch variant {
            case .primary:     LeafColor.text.inverse
            case .secondary:   LeafColor.text.primary
            case .ghost:       LeafColor.text.primary
            case .destructive: LeafColor.text.inverse
            }
        }
    }
}
