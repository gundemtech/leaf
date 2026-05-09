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
                row(.ghost,       label: "ghost")
                row(.secondary,   label: "secondary")
                row(.primary,     label: "primary")
                row(.destructive, label: "destructive")
            }

            TokensInlineSpec(
                spec: "LeafIconButton · square · 4 variants (LeafButtonTokens) · 3 sizes",
                codeSnippet: "LeafIconButton(systemName: \"plus\", variant: .ghost, size: .md) {}"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func row(_ variant: LeafButtonTokens.Variant, label: String) -> some View {
        HStack(spacing: LeafSpace.md) {
            Text(label)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: 96, alignment: .leading)
            LeafIconButton(systemName: "plus",      variant: variant, size: .sm) {}
            LeafIconButton(systemName: "ellipsis",  variant: variant, size: .md) {}
            LeafIconButton(systemName: "trash",     variant: variant, size: .lg) {}
        }
    }
}
#endif
