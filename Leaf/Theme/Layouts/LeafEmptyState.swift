//
//  LeafEmptyState.swift
//  Track 2 / D1 — Organism O7. Vertically-centered empty surface — large SF
//  Symbol + title + optional description + optional CTA. No mascots. Used on
//  Connections, Activity feed, Team grid, Pending invites when the data set
//  is empty.
//

import SwiftUI

struct LeafEmptyState: View {
    let icon: String
    let title: String
    var description: String? = nil
    var ctaTitle: String? = nil
    var onCTA: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: LeafEmptyStateTokens.stackSpacing) {
            Image(systemName: icon)
                .font(.system(size: LeafEmptyStateTokens.iconSize, weight: .light))
                .foregroundStyle(LeafColor.text.quaternary)
            Text(title)
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)
            if let description {
                Text(description)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: LeafEmptyStateTokens.descriptionMaxWidth)
            }
            if let ctaTitle, let onCTA {
                LeafButton(ctaTitle, variant: .primary, size: .md, action: onCTA)
                    .padding(.top, LeafEmptyStateTokens.ctaTopPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LeafEmptyStateTokens.verticalPadding)
    }
}
