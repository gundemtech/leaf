//
//  LeafOnboardingStepLayoutPreview.swift
//  Track 2 / D1 — TokensPreview entry for Template T4 LeafOnboardingStepLayout.
//

import SwiftUI

#if DEBUG
struct LeafOnboardingStepLayoutPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafOnboardingStepLayout").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            LeafOnboardingStepLayout(
                stepIndex: 1,
                totalSteps: 4,
                content: {
                    VStack(alignment: .leading, spacing: LeafSpace.lg) {
                        Text("Connect your team")
                            .font(LeafType.title.large)
                            .foregroundStyle(LeafColor.text.primary)
                        Text("Leaf shares only what you opt-in to. Bring up to 50 teammates onto an end-to-end-encrypted relay.")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                },
                navButtons: {
                    Spacer()
                    LeafSecondaryButton(action: {}) { Text("Back") }
                    LeafProminentButton(action: {}) { Text("Continue") }
                }
            )
            .frame(width: 720, height: 480)
            .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
            .scaleEffect(0.45, anchor: .topLeading)
            .frame(width: 720 * 0.45, height: 480 * 0.45)

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
