//
//  LeafIconButtonPreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M2 LeafIconButton.
//

import SwiftUI

#if DEBUG
struct LeafIconButtonPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafIconButton").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.md) {
                row(.ghost, label: "ghost")
                row(.secondary, label: "secondary")
                row(.primary, label: "primary")
                row(.destructive, label: "destructive")
            }

            TokensInlineSpec(
                spec: "LeafIconButton · square · 4 variants (LeafButtonTokens) · 3 sizes · icon (asset|system)",
                codeSnippet: "LeafIconButton(asset: LeafIcons.action.add, variant: .ghost, size: .md) {}"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func row(_ variant: LeafButtonTokens.Variant, label: String) -> some View {
        HStack(spacing: LeafSpace.md) {
            Text(label)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: 96, alignment: .leading)
            LeafIconButton(asset: LeafIcons.action.add, variant: variant, size: .sm) {}
            LeafIconButton(asset: LeafIcons.action.overflow, variant: variant, size: .md) {}
            LeafIconButton(asset: LeafIcons.object.trash, variant: variant, size: .lg) {}
        }
    }
}
#endif
