//
//  LeafIconPreview.swift
//  Track 2 / D1 — TokensPreview entry for Atom A1 LeafIcon.
//

import SwiftUI

#if DEBUG
struct LeafIconPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafIcon").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)
            HStack(spacing: LeafSpace.lg) {
                LeafIcon(systemName: "leaf.fill", size: .sm)
                LeafIcon(systemName: "leaf.fill", size: .md)
                LeafIcon(systemName: "leaf.fill", size: .lg)
                LeafIcon(systemName: "leaf.fill", size: .md, tint: LeafColor.accent.primary)
                LeafIcon(systemName: "leaf.fill", size: .md, tint: LeafColor.status.danger)
            }
            TokensInlineSpec(
                spec: "LeafIcon · sm/md/lg · tint via LeafColor.*",
                codeSnippet: "LeafIcon(systemName: \"leaf.fill\", size: .md, tint: LeafColor.accent.primary)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
