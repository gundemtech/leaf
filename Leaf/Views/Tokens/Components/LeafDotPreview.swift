//
//  LeafDotPreview.swift
//  Track 2 / D1 — TokensPreview entry for Atom A2 LeafDot.
//

import SwiftUI

#if DEBUG
struct LeafDotPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafDot").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                tonesRow(size: .sm, label: "sm")
                tonesRow(size: .md, label: "md")
                tonesRow(size: .lg, label: "lg")
            }
            TokensInlineSpec(
                spec: "LeafDot · 6 tones (accent/success/warning/danger/info/muted) · 3 sizes",
                codeSnippet: "LeafDot(tone: .success, size: .md)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func tonesRow(size: LeafDotSize, label: String) -> some View {
        HStack(spacing: LeafSpace.lg) {
            Text(label)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: 24, alignment: .leading)
            LeafDot(tone: .accent,  size: size)
            LeafDot(tone: .success, size: size)
            LeafDot(tone: .warning, size: size)
            LeafDot(tone: .danger,  size: size)
            LeafDot(tone: .info,    size: size)
            LeafDot(tone: .muted,   size: size)
        }
    }
}
#endif
