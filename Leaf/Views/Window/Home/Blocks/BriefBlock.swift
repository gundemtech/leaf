//
//  BriefBlock.swift
//  UC-3 — "what shipped while I was out": count rows in the landing-card
//  shape (big number left, label right). v1 scope is local memory (own
//  shipped work); team-mirror aggregation is the follow-up.
//

import LeafCore
import SwiftUI

struct BriefBlock: View {
    @State private var reader = BriefReader()

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
                            : "PR\(brief.prsMerged == 1 ? "" : "s") merged")
                }
                if brief.ticketsDone > 0 {
                    countRow(brief.ticketsDone, "tickets moved to done")
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

    private func countRow(_ count: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LeafSpace.md) {
            Text("\(count)")
                .font(LeafType.title.medium.monospacedDigit())
                .foregroundStyle(LeafColor.text.primary)
                .frame(minWidth: 32, alignment: .trailing)
            Text(label)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label)")
    }
}
