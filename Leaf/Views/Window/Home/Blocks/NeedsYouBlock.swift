//
//  NeedsYouBlock.swift
//  Home redesign — actionable inbox. Default filter `.actionable` ("needs
//  YOUR response NOW" subset); chips now actually narrow the list and show
//  per-filter counts via `InboxFiltering` (LeafCore, tested) — replaces the
//  IV.A.1 stub where every chip displayed `items.count` and the selection
//  was ignored. The in-card search field is gone: ≤100 items under the
//  14-day cutoff don't need a second query surface inside a glance card.
//

import LeafCore
import SwiftUI

struct NeedsYouBlock: View {
    let items: [InboxItem]

    @State private var selectedFilter: InboxFilter = .actionable

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("NEEDS YOU")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .accessibilityAddTraits(.isHeader)

            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    NeedsYouFilterRow(
                        selected: $selectedFilter, counts: InboxFiltering.counts(items))
                    LeafDivider()
                    if items.isEmpty {
                        emptyDataState
                    } else if filteredItems.isEmpty {
                        noMatchState
                    } else {
                        populatedBody
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: filteredItems)
            }
        }
    }

    private var filteredItems: [InboxItem] {
        InboxFiltering.filtered(items, filter: selectedFilter, query: "")
    }

    private var emptyDataState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Nothing waiting on you right now."
        )
    }

    private var noMatchState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Nothing in this filter.",
            description: "Other filters have items — check the counts above.",
            ctaTitle: "Show all",
            onCTA: { selectedFilter = .all }
        )
    }

    private var populatedBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LeafSpace.xs) {
                ForEach(filteredItems) { item in
                    NeedsYouRow(item: item)
                }
            }
        }
        .frame(maxHeight: 320)
    }
}
