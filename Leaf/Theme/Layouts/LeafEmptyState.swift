//
//  LeafEmptyState.swift
//  Track 2 / D1 — Organism O7. Vertically-centered empty surface — neutral
//  LeafIconChip xl (64pt squircle holding a 32pt template glyph) + title +
//  optional description + optional primary CTA. No mascots. Used on
//  Connections, Activity feed, Team grid, Pending invites when the data
//  set is empty.
//

import SwiftUI

struct LeafEmptyState: View {
    /// Asset Catalog name (Figma SVG, template-rendered).
    let icon: String
    let title: String
    var description: String? = nil
    var ctaTitle: String? = nil
    var onCTA: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            LeafIconChip(
                asset: icon,
                size: LeafEmptyStateTokens.chipSize,
                tint: LeafColor.text.tertiary,
                background: LeafColor.text.tertiary.opacity(LeafEmptyStateTokens.chipBackgroundOpacity)
            )
            Spacer().frame(height: LeafEmptyStateTokens.chipTitleGap)

            Text(title)
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            if let description {
                Spacer().frame(height: LeafEmptyStateTokens.titleDescriptionGap)
                Text(description)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: LeafEmptyStateTokens.descriptionMaxWidth)
            }

            if let ctaTitle, let onCTA {
                Spacer().frame(height: LeafEmptyStateTokens.descriptionCTAGap)
                LeafButton(ctaTitle, variant: .primary, size: .md, action: onCTA)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LeafEmptyStateTokens.verticalPadding)
    }
}
