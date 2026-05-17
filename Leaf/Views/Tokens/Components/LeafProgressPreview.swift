//
//  LeafProgressPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O10 LeafProgress.
//

import SwiftUI

#if DEBUG
struct LeafProgressPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafProgress")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("Linear · determinate (0.35)")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                LeafProgress(style: .linear, value: 0.35)

                Text("Linear · indeterminate")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                LeafProgress(style: .linear, value: nil)

                Text("Circular · sm / md / lg · indeterminate")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                HStack(spacing: LeafSpace.lg) {
                    LeafProgress(style: .circular(.sm), value: nil)
                    LeafProgress(style: .circular(.md), value: nil)
                    LeafProgress(style: .circular(.lg), value: nil)
                }

                Text("Circular · md · determinate (0.7)")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                LeafProgress(style: .circular(.md), value: 0.7)
            }

            TokensInlineSpec(
                spec:
                    "LeafProgress · linear (h 4pt) | circular sm/md/lg (16/24/36pt) · determinate Double 0…1 | indeterminate nil",
                codeSnippet: "LeafProgress(style: .linear, value: 0.35)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
