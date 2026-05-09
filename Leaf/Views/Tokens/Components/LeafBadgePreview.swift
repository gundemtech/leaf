//
//  LeafBadgePreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M4 LeafBadge.
//

import SwiftUI

#if DEBUG
struct LeafBadgePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafBadge").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                Text("text variants")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                HStack(spacing: LeafSpace.sm) {
                    LeafBadge(text: "NEW",   variant: .neutral)
                    LeafBadge(text: "BETA",  variant: .accent)
                    LeafBadge(text: "PRO",   variant: .accent)
                }

                Text("numeric (count)")
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                HStack(spacing: LeafSpace.sm) {
                    LeafBadge(count: 1)
                    LeafBadge(count: 12)
                    LeafBadge(count: 99)
                    LeafBadge(count: 100)
                    LeafBadge(count: 9999)
                }
            }

            TokensInlineSpec(
                spec: "LeafBadge · neutral / accent / numeric · LeafType.mono.small",
                codeSnippet: "LeafBadge(count: 12)  // or LeafBadge(text: \"NEW\", variant: .accent)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
