//
//  LeafOnboardingStepLayoutPreview.swift
//  Track 2 / D1 — TokensPreview entry for Template T4 LeafOnboardingStepLayout.
//  LeafOnboardingStepLayout uses .frame(maxWidth/Height: .infinity) (full-bleed
//  step takes whole host window) which doesn't embed cleanly at sub-window
//  scale, so the preview renders a static mockup that diagrams progress
//  capsules + content + nav-buttons using the same tokens. Production
//  usage stays identical to the codeSnippet below.
//

import SwiftUI

#if DEBUG
struct LeafOnboardingStepLayoutPreview: View {
    private let stepIndex = 1
    private let totalSteps = 4

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafOnboardingStepLayout").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(spacing: LeafSpace.xl) {
                HStack(spacing: LeafSpace.xs) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Capsule()
                            .fill(i <= stepIndex ? LeafColor.accent.primary : LeafColor.border.subtle)
                            .frame(height: LeafOnboardingStepLayoutTokens.progressBarHeight)
                    }
                }
                .padding(.horizontal, LeafSpace.xxl)

                Spacer()

                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    Text("Connect your team")
                        .font(LeafType.title.large)
                        .foregroundStyle(LeafColor.text.primary)
                    Text("Leaf shares only what you opt-in to. Bring up to 50 teammates onto an end-to-end-encrypted relay.")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                HStack(spacing: LeafSpace.md) {
                    Spacer()
                    LeafSecondaryButton(action: {}) { Text("Back") }
                    LeafProminentButton(action: {}) { Text("Continue") }
                }
            }
            .padding(LeafSpace.xl)
            .frame(height: 320)
            .background(LeafColor.surface.canvas)
            .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))

            TokensInlineSpec(
                spec: "LeafOnboardingStepLayout · progress capsules h:4 · content maxWidth 560 · padding xxl · canvas bg",
                codeSnippet: "LeafOnboardingStepLayout(stepIndex:1, totalSteps:4, content: { ... }, navButtons: { ... })"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
