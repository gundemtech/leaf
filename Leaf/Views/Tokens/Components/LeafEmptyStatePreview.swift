//
//  LeafEmptyStatePreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O7 LeafEmptyState.
//

import SwiftUI

#if DEBUG
struct LeafEmptyStatePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafEmptyState")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(spacing: LeafSpace.lg) {
                LeafEmptyState(
                    icon: "tray",
                    title: "No connections yet",
                    description: "Connect Linear, GitHub, or Slack to start surfacing activity.",
                    ctaTitle: "Connect a source",
                    onCTA: {}
                )
                LeafEmptyState(
                    icon: "person.2",
                    title: "Just you so far",
                    description: "Invite a teammate to see overlapping focus sessions and presence."
                )
                LeafEmptyState(
                    icon: "magnifyingglass",
                    title: "No matches"
                )
            }

            TokensInlineSpec(
                spec: "LeafEmptyState · 56pt SF Symbol · title + optional desc (maxWidth 360) + optional primary CTA · no mascots",
                codeSnippet: "LeafEmptyState(icon: \"tray\", title: \"No connections yet\")"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
