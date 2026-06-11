//
//  BriefBlock.swift
//  UC-3 — "what shipped while I was out": count rows in the landing-card
//  shape (big number left, label right). v1 scope is local memory (own
//  shipped work); team-mirror aggregation is the follow-up.
//

import AppKit
import LeafCore
import SwiftUI

struct BriefBlock: View {
    @State private var reader = BriefReader()
    @State private var prsExpanded = false
    @State private var ticketsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("BRIEF · LAST \(BriefReader.periodDays) DAYS")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
                .accessibilityAddTraits(.isHeader)

            LeafCard(padding: .regular) {
                content
            }
        }
        .task { await reader.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .idle, .loading:
            HStack(spacing: LeafSpace.sm) {
                ProgressView().controlSize(.small)
                Text("Composing brief…")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            }
        case .empty:
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Nothing shipped in the last \(BriefReader.periodDays) days yet.",
                description: "Merged PRs, closed tickets and surfaced decisions land here."
            )
        case .error:
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "Couldn't compose the brief.",
                description: "Try reopening the window."
            )
        case .loaded(let brief):
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                if brief.prsMerged > 0 {
                    countRow(
                        brief.prsMerged,
                        brief.reposTouched > 1
                            ? "PRs merged across \(brief.reposTouched) repos"
                            : "PR\(brief.prsMerged == 1 ? "" : "s") merged",
                        items: brief.prItems,
                        expanded: $prsExpanded)
                }
                if brief.ticketsDone > 0 {
                    countRow(
                        brief.ticketsDone, "tickets moved to done",
                        items: brief.ticketItems,
                        expanded: $ticketsExpanded)
                }
                if brief.decisionsSurfaced > 0 {
                    countRow(brief.decisionsSurfaced, "decisions surfaced")
                }
                if brief.blockersResolved > 0 {
                    countRow(brief.blockersResolved, "blockers resolved")
                }
                if brief.commitsPushed > 0 {
                    countRow(brief.commitsPushed, "commits pushed")
                }
                if brief.reviewsAuthored > 0 {
                    countRow(brief.reviewsAuthored, "reviews authored")
                }
            }
        }
    }

    /// Counter line; when `items` are provided the row toggles an inline
    /// detail list ("which PRs exactly") with a chevron affordance.
    @ViewBuilder
    private func countRow(
        _ count: Int, _ label: String,
        items: [BriefItem] = [], expanded: Binding<Bool>? = nil
    ) -> some View {
        let canExpand = !items.isEmpty && expanded != nil
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Button {
                if let expanded {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expanded.wrappedValue.toggle()
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: LeafSpace.md) {
                    Text("\(count)")
                        .font(LeafType.title.medium.monospacedDigit())
                        .foregroundStyle(LeafColor.text.primary)
                        .frame(minWidth: 32, alignment: .trailing)
                    Text(label)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.secondary)
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(LeafType.label)
                            .foregroundStyle(LeafColor.text.quaternary)
                            .rotationEffect(.degrees(expanded?.wrappedValue == true ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityLabel("\(count) \(label)\(canExpand ? ", tap to expand" : "")")

            if canExpand, expanded?.wrappedValue == true {
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    ForEach(items) { item in
                        itemRow(item)
                    }
                }
                .padding(.leading, LeafSpace.xxl)
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: BriefItem) -> some View {
        Button {
            if let url = item.sourceURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: LeafSpace.xs) {
                Text(item.ref)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                if let title = item.title {
                    Text(title)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(item.sourceURL == nil ? [] : .isButton)
    }
}
