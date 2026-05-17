//
//  LeafStatusPillPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O5 LeafStatusPill.
//

import SwiftUI

#if DEBUG
struct LeafStatusPillPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafStatusPill")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            HStack(spacing: LeafSpace.lg) {
                LeafStatusPill(state: .idle)
                LeafStatusPill(state: .active)
                LeafStatusPill(state: .sharing)
                LeafStatusPill(state: .invisible)
            }

            TokensInlineSpec(
                spec:
                    "LeafStatusPill · idle/active/sharing/invisible · pulsing halo on active+sharing · reduce-motion-respecting",
                codeSnippet: "LeafStatusPill(state: .active)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
