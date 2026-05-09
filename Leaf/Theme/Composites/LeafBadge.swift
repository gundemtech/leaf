//
//  LeafBadge.swift
//  Track 2 / D1 — Molecule M4. Compact label badge.
//  Variants: neutral / accent / numeric. Numeric init caps display at "99+".
//

import SwiftUI

struct LeafBadge: View {
    let text: String
    var variant: LeafBadgeTokens.Variant = .neutral

    init(text: String, variant: LeafBadgeTokens.Variant = .neutral) {
        self.text = text
        self.variant = variant
    }

    init(count: Int) {
        self.text = count > 99 ? "99+" : String(count)
        self.variant = .numeric
    }

    var body: some View {
        Text(text)
            .font(LeafType.mono.small)
            .foregroundStyle(fg)
            .padding(.horizontal, LeafSpace.xs)
            .padding(.vertical, LeafSpace.xxs)
            .background(Capsule().fill(bg))
    }

    private var bg: Color {
        switch variant {
        case .neutral: LeafColor.surface.inset
        case .accent:  LeafColor.accent.subtle
        case .numeric: LeafColor.accent.primary
        }
    }

    private var fg: Color {
        switch variant {
        case .neutral: LeafColor.text.secondary
        case .accent:  LeafColor.accent.emphasis
        case .numeric: LeafColor.text.inverse
        }
    }
}
