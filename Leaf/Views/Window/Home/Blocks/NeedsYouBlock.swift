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
    /// Auto-fallthrough runs once per appearance: an empty default filter
    /// must not render a giant empty card while "All" silently holds items.
    /// After the first correction the user's explicit chip taps win.
    @State private var didAutoSelect = false

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
                        compactAllClear("Nothing waiting on you right now.")
                    } else if filteredItems.isEmpty {
                        compactAllClear(
                            selectedFilter == .actionable
                                ? "Nothing needs your response — informational items are under All."
                                : "Nothing in this filter — check the counts above.")
                    } else {
                        populatedBody
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: filteredItems)
            }
        }
        .onChange(of: items, initial: true) { _, newItems in
            guard !didAutoSelect, selectedFilter == .actionable else { return }
            let counts = InboxFiltering.counts(newItems)
            if counts[.actionable] == 0, (counts[.all] ?? 0) > 0 {
                selectedFilter = .all
                didAutoSelect = true
            }
        }
    }

    private var filteredItems: [InboxItem] {
        InboxFiltering.filtered(items, filter: selectedFilter, query: "")
    }

    /// Single-row all-clear (the former full-height LeafEmptyState dominated
    /// half the screen for the happy path).
    private func compactAllClear(_ text: String) -> some View {
        HStack(spacing: LeafSpace.sm) {
            Image(systemName: "checkmark.circle")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.status.success)
                .accessibilityHidden(true)
            Text(text)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, LeafSpace.xs)
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
