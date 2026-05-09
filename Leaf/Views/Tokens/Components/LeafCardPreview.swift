//
//  LeafCardPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O1 LeafCard.
//

import SwiftUI

#if DEBUG
struct LeafCardPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafCard").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.md) {
                LeafCard(variant: .rest, padding: .regular) {
                    Text("Rest variant — flat, no fill")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }

                LeafCard(variant: .raised, padding: .regular) {
                    Text("Raised variant — surface.raised + shadow")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }

                LeafCard(variant: .glass, padding: .regular) {
                    Text("Glass variant — .leafGlass(.regular)")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }

                LeafCard(
                    variant: .raised,
                    padding: .generous,
                    header: {
                        Text("Card with header / content / footer")
                            .font(LeafType.title.small)
                            .foregroundStyle(LeafColor.text.primary)
                    },
                    content: {
                        Text("Content slot — body lines, charts, lists.")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.secondary)
                    },
                    footer: {
                        HStack {
                            Spacer()
                            LeafBadge(text: "v0.1", variant: .neutral)
                        }
                    }
                )
            }

            TokensInlineSpec(
                spec: "LeafCard · rest/raised/glass · padding tight/regular/generous · radius LeafRadius.lg · raised elevation",
                codeSnippet: "LeafCard(variant: .raised, padding: .regular) { Text(\"…\") }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
