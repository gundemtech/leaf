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

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("INBOX")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)

            LeafCard(padding: .regular) {
                if items.isEmpty {
                    emptyDataState
                } else {
                    placeholderPopulated
                }
            }
        }
    }

    private var emptyDataState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "All clear.",
            description: "No reviews, questions, or mentions right now."
        )
    }

    // Placeholder until T4–T9 add the real UI (filter row + search +
    // scrollable list with severity dots + aggregation count + tap).
    private var placeholderPopulated: some View {
        Text("\(items.count) inbox items")
            .font(LeafType.body.regular)
            .foregroundStyle(LeafColor.text.secondary)
    }
}
