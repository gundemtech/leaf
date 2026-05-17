//
//  LeafDividerPreview.swift
//  Track 2 / D1 — TokensPreview entry for Atom A3 LeafDivider.
//

import SwiftUI

#if DEBUG
struct LeafDividerPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafDivider").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                labelled("hairline") { LeafDivider(style: .hairline) }
                labelled("soft") { LeafDivider(style: .soft) }
            }
            TokensInlineSpec(
                spec: "LeafDivider · hairline / soft · 1pt LeafColor.border.subtle",
                codeSnippet: "LeafDivider(style: .hairline)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func labelled<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text(label)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
            content()
        }
    }
}
#endif
