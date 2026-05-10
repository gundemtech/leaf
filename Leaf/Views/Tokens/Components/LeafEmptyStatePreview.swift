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
                    icon: LeafIcons.object.appPlaceholder,
                    title: "No connections yet",
                    description: "Connect Linear, GitHub, or Slack to start surfacing activity.",
                    ctaTitle: "Connect a source",
                    onCTA: {}
                )
                LeafEmptyState(
                    icon: LeafIcons.object.userError,
                    title: "Just you so far",
                    description: "Invite a teammate to see overlapping focus sessions and presence."
                )
                LeafEmptyState(
                    icon: LeafIcons.object.folderEmpty,
                    title: "No matches"
                )
            }

            TokensInlineSpec(
                spec: "LeafEmptyState · 56pt asset glyph · title + optional desc (maxWidth 360) + optional primary CTA · no mascots",
                codeSnippet: "LeafEmptyState(icon: LeafIcons.object.folderEmpty, title: \"No matches\")"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
