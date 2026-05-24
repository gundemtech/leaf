//
//  NeedsYouBlock.swift
//  Track 8 / Phase 8.6 — originally InboxBlock. Track-10 T4 — renamed and
//  scope-tightened: default filter flipped from `.all` to `.actionable`
//  so Home opens on the 7-kind "needs YOUR response NOW" subset; `[All]`
//  chip remains the escape hatch for the 7 dropped informational kinds.
//  Wires `DerivedInsights.inboxItems(filter:query:)` substrate through
//  `InsightsSnapshot.inboxItems`. Filter + search are view-side @State;
//  no SQL re-fetch on keystroke (≤100 items per 14-day cutoff).
//

import LeafCore
import SwiftUI

struct NeedsYouBlock: View {
    let items: [InboxItem]

    @State private var selectedFilter: InboxFilter = .actionable
    @State private var searchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("NEEDS YOU")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    LeafInput(
                        text: $searchQuery,
                        placeholder: "Search inbox…",
                        prefixIcon: .system("magnifyingglass")
                    )
                    NeedsYouFilterRow(selected: $selectedFilter, counts: counts(for: items))
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
        // IV.A.1 — InboxFiltering type dropped III.B. Inline minimal filter
        // (all + query substring match); defer full filter matrix to IV.A.2.
        items.filter { item in
            searchQuery.isEmpty || item.title.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    /// Per-chip counts for the filter strip. Reuses `filteredItems` minimal
    /// stub; IV.A.2 will restore full InboxFilter matrix.
    private func counts(for items: [InboxItem]) -> [InboxFilter: Int] {
        var dict: [InboxFilter: Int] = [:]
        for filter in InboxFilter.allCases {
            dict[filter] = items.count
        }
        return dict
    }

    private var emptyDataState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Nothing waiting on you right now."
        )
    }

    private var noMatchState: some View {
        // C-18 (Phase 8.9) — magnifying-glass SF Symbol differentiates the
        // "search miss" state from the all-clear leaf icon used by
        // `emptyDataState`. Same `LeafEmptyState` shape; only the leading
        // icon glyph changes.
        LeafEmptyState(
            icon: LeafIcons.nav.searchSF,
            title: "No matches.",
            description: "Try a different filter or clear the search.",
            ctaTitle: "Clear filters",
            onCTA: {
                // T4 — reset target is `.actionable` (the new default), not
                // `.all`. "Clear filters" returns user to the fresh NEEDS YOU view.
                selectedFilter = .actionable
                searchQuery = ""
            }
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
