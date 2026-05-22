//
//  InboxBlock.swift
//  Track 8 / Phase 8.6 — INBOX dashboard block. Wires
//  `DerivedInsights.inboxItems(filter:query:)` substrate through
//  `InsightsSnapshot.inboxItems`. Filter + search are view-side @State;
//  no SQL re-fetch on keystroke (≤100 items per 14-day cutoff).
//

import LeafCore
import SwiftUI

struct InboxBlock: View {
    let items: [InboxItem]

    @State private var selectedFilter: InboxFilter = .all
    @State private var searchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("INBOX")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    LeafInput(
                        text: $searchQuery,
                        placeholder: "Search inbox…",
                        prefixIcon: .system("magnifyingglass")
                    )
                    InboxFilterRow(selected: $selectedFilter, counts: counts(for: items))
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
        InboxFiltering.filtered(items: items, filter: selectedFilter, query: searchQuery)
    }

    /// Per-chip counts for the filter strip. Each chip's `· N` reflects the
    /// exact list a user would see after tapping it (filter ∩ query). Reuses
    /// `InboxFiltering.filtered` as the single source of truth so chip counts
    /// can never drift from the rendered list. ≤30 items × 6 filters per
    /// render is negligible on M-series; profile only if narrow Macs surface
    /// stutter under sustained typing (carry C-T4-2).
    private func counts(for items: [InboxItem]) -> [InboxFilter: Int] {
        var dict: [InboxFilter: Int] = [:]
        for filter in InboxFilter.allCases {
            dict[filter] = InboxFiltering.filtered(
                items: items, filter: filter, query: searchQuery
            ).count
        }
        return dict
    }

    private var emptyDataState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "All clear.",
            description: "No reviews, questions, or mentions right now."
        )
    }

    private var noMatchState: some View {
        // C-18 (Phase 8.9) — magnifying-glass SF Symbol differentiates the
        // "search miss" state from the positive "All clear" leaf icon used by
        // `emptyDataState`. Same `LeafEmptyState` shape; only the leading
        // icon glyph changes.
        LeafEmptyState(
            icon: LeafIcons.nav.searchSF,
            title: "No matches.",
            description: "Try a different filter or clear the search.",
            ctaTitle: "Clear filters",
            onCTA: {
                selectedFilter = .all
                searchQuery = ""
            }
        )
    }

    private var populatedBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LeafSpace.xs) {
                ForEach(filteredItems) { item in
                    InboxItemRow(item: item)
                }
            }
        }
        .frame(maxHeight: 320)
    }
}
