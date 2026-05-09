//
//  LeafIconButton.swift
//  Track 2 / D1 — Molecule M2. Square icon-only button. Shares LeafButtonTokens
//  (Variant + Size). Frame is square (size.height × size.height); icon point
//  size derived as 0.45 × height for visual parity with text buttons at the
//  same Size.
//

import SwiftUI

struct LeafIconButton: View {
    let systemName: String
    var variant: LeafButtonTokens.Variant = .ghost
    var size: LeafButtonTokens.Size = .md
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size.height * 0.45, weight: .regular))
                .foregroundStyle(LeafButtonTokens.Foreground.resting(variant))
                .frame(width: size.height, height: size.height)
                .background(
                    RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous)
                        .fill(isHovering
                              ? LeafButtonTokens.Background.hover(variant)
                              : LeafButtonTokens.Background.resting(variant))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .leafAnimation(LeafMotion.spring.snappy, value: isHovering)
    }
}
