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

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("INBOX")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
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
        items.filter { selectedFilter.admits($0.kind) }
    }

    private var emptyDataState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "All clear.",
            description: "No reviews, questions, or mentions right now."
        )
    }

    // Placeholder until T5 adds search + T6..T9 add scrollable list.
    private var placeholderPopulated: some View {
        Text("\(filteredItems.count) inbox items (filter: \(selectedFilter.rawValue))")
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.secondary)
    }
}
