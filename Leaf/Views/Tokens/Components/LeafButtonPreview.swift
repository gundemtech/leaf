//
//  LeafButtonPreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M1 LeafButton.
//

import SwiftUI

#if DEBUG
struct LeafButtonPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafButton").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.md) {
                variantRow(.primary,     label: "primary")
                variantRow(.secondary,   label: "secondary")
                variantRow(.ghost,       label: "ghost")
                variantRow(.destructive, label: "destructive")
            }

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("with icon · loading")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                HStack(spacing: LeafSpace.md) {
                    LeafButton("Save", variant: .primary, size: .md, icon: "tray.and.arrow.down") {}
                    LeafButton("Loading", variant: .primary, size: .md, isLoading: true) {}
                    LeafButton("Delete", variant: .destructive, size: .md, icon: "trash") {}
                }
            }

            TokensInlineSpec(
                spec: "LeafButton · 4 variants · 3 sizes · icon · loading · LeafRadius.md",
                codeSnippet: "LeafButton(\"Save\", variant: .primary, size: .md, icon: \"tray.and.arrow.down\") {}"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func variantRow(_ variant: LeafButtonTokens.Variant, label: String) -> some View {
        HStack(spacing: LeafSpace.md) {
            Text(label)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: 96, alignment: .leading)
            LeafButton("Small", variant: variant, size: .sm) {}
            LeafButton("Medium", variant: variant, size: .md) {}
            LeafButton("Large", variant: variant, size: .lg) {}
        }
    }
}
#endif
