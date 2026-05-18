//
//  AnalyticsView.swift
//  Track 8 / Phase 8.8 — Analytics tab placeholder. Replaces the prior
//  ActivityView (Sessions feed + raw events list) which actively misled
//  users with noisy data and no insight. Real Analytics surface (week
//  breakdown chart, deep-work streaks, peak-hour, top tools, WoW deltas)
//  lands in Track-9 after Track-8 wraps.
//

import SwiftUI

struct AnalyticsView: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                header
                placeholderCard
            }
            .padding(LeafSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        Text("Analytics")
            .font(LeafType.title.large)
            .foregroundStyle(LeafColor.text.primary)
    }

    private var placeholderCard: some View {
        LeafCard(padding: .regular) {
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Analytics view coming soon",
                description: "Patterns, trends, and weekly summaries will land here."
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
