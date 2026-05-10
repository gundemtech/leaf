//
//  LeafSectionPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O2 LeafSection.
//

import SwiftUI

#if DEBUG
struct LeafSectionPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafSection").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.xl) {
                LeafSection(title: "Title only") {
                    Text("Content slot — body lines, lists, charts.")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.secondary)
                }

                LeafSection(
                    title: "Title + description",
                    description: "Helpful context for the section, rendered in body.small."
                ) {
                    Text("Content slot — multiple rows of related controls.")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.secondary)
                }

                LeafSection(
                    title: "Title + CTA",
                    description: "CTA slot pinned top-right.",
                    content: {
                        Text("Content slot — sub-area below the header row.")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.secondary)
                    },
                    cta: {
                        LeafButton("Add", variant: .secondary, size: .sm) {}
                    }
                )
            }

            TokensInlineSpec(
                spec: "LeafSection · title (LeafType.title.medium) · description (LeafType.body.small) · CTA top-right",
                codeSnippet: "LeafSection(title: \"Connections\") { ... }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
