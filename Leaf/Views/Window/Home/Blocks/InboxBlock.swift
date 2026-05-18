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
                    InboxFilterRow(selected: $selectedFilter)
                    LeafDivider()
                    if items.isEmpty {
                        emptyDataState
                    } else {
                        placeholderPopulated
                    }
                }
            }
        }
    }

    private var filteredItems: [InboxItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            guard selectedFilter.admits(item.kind) else { return false }
            guard !trimmed.isEmpty else { return true }
            return item.title.lowercased().contains(trimmed)
                || item.sourceMeta.lowercased().contains(trimmed)
        }
    }

    private var emptyDataState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "All clear.",
            description: "No reviews, questions, or mentions right now."
        )
    }

    // Placeholder until T6..T9 add scrollable list with row + tap + count.
    private var placeholderPopulated: some View {
        Text("\(filteredItems.count) inbox items (filter: \(selectedFilter.rawValue), query: '\(searchQuery)')")
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.secondary)
    }
}
