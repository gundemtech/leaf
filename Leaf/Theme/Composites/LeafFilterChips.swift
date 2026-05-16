//
//  LeafFilterChips.swift
//  Track 5 / S7 B.6 — Composite. Horizontal pill row for TeamFeed filter
//  selection. Shows up to N visible chips + "More…" pill that opens a popover
//  with additional toggle rows for ShareSource filters.
//
//  Mutex rule (spec §4.5):
//   • Selecting `.all` clears all other filters (selected = [.all]).
//   • Selecting any other filter removes `.all` from the set.
//   • Deselecting the last active non-`.all` filter restores [.all].
//

import SwiftUI
import LeafCore

struct LeafFilterChips: View {

    /// Filters shown as inline pill chips (spec recommends ≤5 for narrow bar).
    let visibleFilters: [FeedFilter]

    /// Filters available inside the "More…" popover (typically ShareSource cases).
    let popoverFilters: [FeedFilter]

    /// Currently selected set — caller owns state via @State or @Binding.
    @Binding var selected: Set<FeedFilter>

    @State private var popoverOpen = false

    init(
        visibleFilters: [FeedFilter],
        popoverFilters: [FeedFilter],
        selected: Binding<Set<FeedFilter>>
    ) {
        self.visibleFilters = visibleFilters
        self.popoverFilters = popoverFilters
        self._selected = selected
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: LeafFilterChipsTokens.chipSpacing) {
            ForEach(visibleFilters, id: \.self) { filter in
                chipView(filter)
            }
            if !popoverFilters.isEmpty {
                morePillView
            }
        }
    }

    // MARK: - Chip

    @ViewBuilder
    private func chipView(_ filter: FeedFilter) -> some View {
        let isOn = selected.contains(filter)
        LeafPill(title: filter.displayLabel, tone: isOn ? .accent : .neutral)
            .onTapGesture { toggle(filter) }
    }

    // MARK: - More pill + popover

    private var morePillView: some View {
        LeafPill(
            title: "More\u{2026}",   // "More…" — avoids trigraph warning
            tone: popoverHasActiveFilter ? .accent : .neutral
        )
        .onTapGesture { popoverOpen.toggle() }
        .popover(isPresented: $popoverOpen, arrowEdge: .bottom) {
            popoverContent
        }
    }

    /// True when any popoverFilter is currently selected (highlights the pill).
    private var popoverHasActiveFilter: Bool {
        popoverFilters.contains(where: { selected.contains($0) })
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            ForEach(popoverFilters, id: \.self) { filter in
                Toggle(isOn: Binding(
                    get: { selected.contains(filter) },
                    set: { _ in toggle(filter) }
                )) {
                    Text(filter.displayLabel)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }
                .toggleStyle(.checkbox)
                .frame(height: LeafFilterChipsTokens.popoverRowHeight)
            }
        }
        .padding(LeafFilterChipsTokens.popoverPadding)
        .frame(minWidth: LeafFilterChipsTokens.popoverMinWidth)
    }

    // MARK: - Selection logic

    private func toggle(_ filter: FeedFilter) {
        if filter.isExclusive {
            // Selecting .all collapses everything
            selected = [.all]
            return
        }
        // Any other filter: remove .all first
        selected.remove(.all)
        if selected.contains(filter) {
            selected.remove(filter)
            // Restore .all if set would be empty
            if selected.isEmpty { selected = [.all] }
        } else {
            selected.insert(filter)
        }
    }
}
