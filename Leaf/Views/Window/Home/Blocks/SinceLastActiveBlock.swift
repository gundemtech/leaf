//
//  SinceLastActiveBlock.swift
//  Track-10 T5 — Zone-5 Home block: SINCE YOU WERE LAST ACTIVE timeline.
//
//  Header "SINCE YOU WERE LAST ACTIVE" + LeafCard with filter chip strip
//  (All / Linear / GitHub / Slack / Detections) + 20-row inline-expand cap
//  ("+N older changes" toggle) + Mark-all-as-seen footer.
//
//  Filter is view-side narrowing only; `onMarkAllAsSeen` advances the global
//  LastSeenCursor (Q5 single global cursor decision) which the caller wires
//  to InsightsReader.refresh() to repopulate the snapshot.
//

import LeafCore
import SwiftUI

struct SinceLastActiveBlock: View {
    let items: [SinceLastActiveItem]
    let onMarkAllAsSeen: () -> Void

    @State private var selectedFilter: SinceFilter = .all
    @State private var isExpanded: Bool = false

    // Home redesign — 8 rows keep the block a glance surface; the full
    // stream lives in the Activity tab. "+N older changes" expands inline.
    private static let visibleCap = 8

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("WHILE YOU WERE AWAY")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .accessibilityAddTraits(.isHeader)

            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    SinceFilterRow(selected: $selectedFilter, counts: counts)
                    LeafDivider()
                    contentBody
                }
                .animation(.easeInOut(duration: 0.25), value: filteredItems)
            }
        }
    }

    private var filteredItems: [SinceLastActiveItem] {
        items.filter { selectedFilter.admits($0.source) }
    }

    private var counts: [SinceFilter: Int] {
        var dict: [SinceFilter: Int] = [.all: items.count]
        for filter in SinceFilter.allCases where filter != .all {
            dict[filter] = items.filter { filter.admits($0.source) }.count
        }
        return dict
    }

    @ViewBuilder
    private var contentBody: some View {
        let visible = filteredItems
        if items.isEmpty {
            emptyDataState
        } else if visible.isEmpty {
            noMatchState
        } else {
            populatedBody(visible: visible)
        }
    }

    private var emptyDataState: some View {
        LeafEmptyState(
            icon: LeafIcons.brand.leaf,
            title: "Nothing new since you last looked."
        )
    }

    private var noMatchState: some View {
        LeafEmptyState(
            icon: LeafIcons.nav.searchSF,
            title: "No matches in this filter.",
            description: "Switch filter or mark all as seen.",
            ctaTitle: "Show all",
            onCTA: { selectedFilter = .all }
        )
    }

    @ViewBuilder
    private func populatedBody(visible: [SinceLastActiveItem]) -> some View {
        let cap = isExpanded ? visible.count : min(visible.count, Self.visibleCap)
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            ForEach(Array(visible.prefix(cap)), id: \.uniqueKey) { item in
                SinceLastActiveRow(item: item)
            }
            if visible.count > Self.visibleCap {
                expandFooter(remaining: visible.count - Self.visibleCap)
            }
            markAllFooter
        }
    }

    private func expandFooter(remaining: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            Text(isExpanded ? "Collapse" : "+\(remaining) older changes")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, LeafSpace.xs)
    }

    private var markAllFooter: some View {
        HStack {
            Spacer()
            Button("Mark all as seen") {
                onMarkAllAsSeen()
            }
            .buttonStyle(.borderless)
            .font(LeafType.body.small)
        }
        .padding(.top, LeafSpace.xs)
    }
}
