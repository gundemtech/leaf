//
//  LeafEmptyState.swift
//  Track 2 / D1 — Organism O7. Vertically-centered empty surface — neutral
//  LeafIconChip xl (64pt squircle holding a 32pt template glyph) + title +
//  optional description + optional primary CTA. No mascots. Used on
//  Connections, Activity feed, Team grid, Pending invites when the data
//  set is empty.
//
//  Track-10 Phase A (GUN-A) — `.compact` style variant for inline use
//  inside collapsible cards (Recap / Eod / YoureOn). 24pt chip + inline
//  HStack + no CTA — keeps the empty surface from dominating a short
//  card footprint.
//

import SwiftUI

struct LeafEmptyState: View {
    enum Style { case large, compact }

    /// Asset Catalog name (Figma SVG, template-rendered).
    let icon: String
    let title: String
    var description: String? = nil
    var ctaTitle: String? = nil
    var onCTA: (() -> Void)? = nil
    var style: Style = .large

    var body: some View {
        switch style {
        case .large: largeBody
        case .compact: compactBody
        }
    }

    private var largeBody: some View {
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

    private var compactBody: some View {
        HStack(alignment: .center, spacing: LeafSpace.sm) {
            LeafIconChip(
                asset: icon,
                size: LeafEmptyStateTokens.compactChipSize,
                tint: LeafColor.text.tertiary,
                background: LeafColor.text.tertiary.opacity(LeafEmptyStateTokens.chipBackgroundOpacity)
            )
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(title)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                if let description {
                    Text(description)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LeafSpace.xs)
    }
}
