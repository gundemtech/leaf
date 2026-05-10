//
//  LeafOnboardingStepLayout.swift
//  Track 2 / D1 — Template T4. Full-bleed onboarding step layout: progress
//  capsules at top · content slot in the middle (max-width capped) · nav
//  buttons at the bottom. Heights surfaced via LeafOnboardingStepLayoutTokens.
//

import SwiftUI

struct LeafOnboardingStepLayout<Content: View, Nav: View>: View {
    let stepIndex: Int
    let totalSteps: Int
    @ViewBuilder let content: () -> Content
    @ViewBuilder let navButtons: () -> Nav

    var body: some View {
        VStack(spacing: LeafSpace.xl) {
            HStack(spacing: LeafSpace.xs) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= stepIndex ? LeafColor.accent.primary : LeafColor.border.subtle)
                        .frame(height: LeafOnboardingStepLayoutTokens.progressBarHeight)
                }
            }
            .padding(.horizontal, LeafSpace.xxxl)

            Spacer()

            content()
                .frame(maxWidth: LeafOnboardingStepLayoutTokens.contentMaxWidth)

            Spacer()

            HStack(spacing: LeafSpace.md) {
                navButtons()
            }
        }
        .padding(LeafSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LeafColor.surface.canvas)
    }
}
