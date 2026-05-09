//
//  TokensMotionSection.swift
//  Track 2 / D1 — Preview rows for LeafMotion.* — live demos under .leafAnimation.
//

import SwiftUI

#if DEBUG
struct TokensMotionSection: View {
    @State private var nudge = false

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Motion").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                row("spring.snappy",     LeafMotion.spring.snappy)
                row("spring.gentle",     LeafMotion.spring.gentle)
                row("spring.bouncy",     LeafMotion.spring.bouncy)
                row("easing.standard",   LeafMotion.easing.standard)
                row("easing.emphasized", LeafMotion.easing.emphasized)
            }
            Button("Nudge") { nudge.toggle() }
                .buttonStyle(.bordered)
                .tint(LeafColor.accent.primary)
        }
    }

    private func row(_ name: String, _ animation: Animation) -> some View {
        HStack(spacing: LeafSpace.lg) {
            Text(name).font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: 160, alignment: .leading)
            Circle()
                .fill(LeafColor.accent.primary)
                .frame(width: LeafSpace.xl, height: LeafSpace.xl)
                .offset(x: nudge ? 120 : 0)
                .leafAnimation(animation, value: nudge)
        }
    }
}
#endif
