//
//  LeafSpacerPreview.swift
//  Track 2 / D1 — TokensPreview entry for Atom A4 LeafSpacer.
//

import SwiftUI

#if DEBUG
struct LeafSpacerPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafSpacer").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            // Visualised fixed sizes — coloured rect of LeafSpace.* dimension.
            HStack(spacing: LeafSpace.sm) {
                fixed("sm", LeafSpace.sm)
                fixed("md", LeafSpace.md)
                fixed("lg", LeafSpace.lg)
                fixed("xl", LeafSpace.xl)
                fixed("xxl", LeafSpace.xxl)
            }

            // Flexible variant — pushes leading and trailing markers apart.
            HStack(spacing: 0) {
                Text("◀")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                LeafSpacer()
                Text("flexible")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                LeafSpacer()
                Text("▶")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
            .padding(.vertical, LeafSpace.xs)

            TokensInlineSpec(
                spec: "LeafSpacer · fixed (LeafSpace.*) or flexible",
                codeSnippet: "LeafSpacer(LeafSpace.lg)  // or LeafSpacer()"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func fixed(_ label: String, _ size: CGFloat) -> some View {
        VStack(spacing: LeafSpace.xs) {
            Rectangle()
                .fill(LeafColor.accent.subtle)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous))
            Text(label)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
#endif
