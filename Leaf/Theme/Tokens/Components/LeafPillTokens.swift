//
//  LeafPillTokens.swift
//  Track 2 / D1 — T3 tokens for LeafPill. Tone enum maps to subtle background +
//  foreground (text + icon + dot tint).
//

import SwiftUI

enum LeafPillTokens {
    enum Tone {
        case neutral, accent, success, warning, danger

        var bg: Color {
            switch self {
            case .neutral: LeafColor.surface.inset
            case .accent: LeafColor.accent.subtle
            case .success: LeafColor.status.success.opacity(0.12)
            case .warning: LeafColor.status.warning.opacity(0.14)
            case .danger: LeafColor.status.danger.opacity(0.12)
            }
        }

        var fg: Color {
            switch self {
            case .neutral: LeafColor.text.secondary
            case .accent: LeafColor.accent.emphasis
            case .success: LeafColor.status.success
            case .warning: LeafColor.status.warning
            case .danger: LeafColor.status.danger
            }
        }

        var dotTone: LeafDotTone {
            switch self {
            case .neutral: .muted
            case .accent: .accent
            case .success: .success
            case .warning: .warning
            case .danger: .danger
            }
        }
    }
}
