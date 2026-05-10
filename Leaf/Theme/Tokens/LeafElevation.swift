//
//  LeafElevation.swift
//  Track 2 / D1 — Tier 2 shadow tokens. View-modifier wrappers so
//  consumers write .leafElevation(LeafElevation.raised) instead of raw .shadow(...).
//  Light/dark opacity values pick from @Environment(\.colorScheme).
//

import SwiftUI

enum LeafElevation {
    /// y=0 blur=0 — flat, applies no shadow modifier (composes onto views without effect).
    static let flat = Shadow(y: 0, blur: 0, opacityLight: 0, opacityDark: 0)

    /// y=1 blur=3 — subtle raise. Light .04, Dark .50.
    static let raised = Shadow(y: 1, blur: 3, opacityLight: 0.04, opacityDark: 0.50)

    /// y=4 blur=12 — floating cards, popovers. Light .08, Dark .60.
    static let floating = Shadow(y: 4, blur: 12, opacityLight: 0.08, opacityDark: 0.60)

    /// y=24 blur=48 — modal overlay. Light .18, Dark .70.
    static let modal = Shadow(y: 24, blur: 48, opacityLight: 0.18, opacityDark: 0.70)

    struct Shadow {
        let y: CGFloat
        let blur: CGFloat
        let opacityLight: Double
        let opacityDark: Double
    }
}

extension View {
    /// Apply elevation token. Reads `colorScheme` to pick light/dark opacity
    /// of an otherwise-black base shadow. Flat → no-op.
    func leafElevation(_ shadow: LeafElevation.Shadow) -> some View {
        modifier(LeafElevationModifier(shadow: shadow))
    }
}

private struct LeafElevationModifier: ViewModifier {
    let shadow: LeafElevation.Shadow
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if shadow.blur == 0 {
            content
        } else {
            let opacity = colorScheme == .dark ? shadow.opacityDark : shadow.opacityLight
            content.shadow(
                color: Color.black.opacity(opacity),
                radius: shadow.blur,
                x: 0,
                y: shadow.y
            )
        }
    }
}
