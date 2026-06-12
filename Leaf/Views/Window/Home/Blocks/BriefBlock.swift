//
//  BriefBlock.swift
//  UC-3 — "what shipped while I was out": the landing-page Monday-brief
//  card. Track B3: team-mirror aggregation (teammates' shared events count
//  alongside own work), terminal-card chrome, "read full brief →" detail
//  sheet, Monday header.
//

import AppKit
import LeafCore
import SwiftUI

struct BriefBlock: View {
    @Environment(ActiveWorkspaceStore.self) private var activeWorkspaceStore
    @State private var reader = BriefReader()
    @State private var prsExpanded = false
    @State private var ticketsExpanded = false
    @State private var detailPresented = false

    var body: some View {
        LeafCard(padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                LeafTerminalCardHeader(
                    dotTone: .success,
                    title: Self.headerTitle(),
                    detail: "last \(BriefReader.periodDays) days"
                ) {
                    if case .loaded = reader.state {
                        LeafStatusBadge(text: "live", showDot: true)
                    }
                }

                content
            }
        }
        .task(id: activeWorkspaceStore.activeWorkspaceID) {
            await reader.refresh(workspaceID: activeWorkspaceStore.activeWorkspaceID)
        }
        .sheet(isPresented: $detailPresented) {
            BriefDetailSheet(detail: reader.detail, periodDays: BriefReader.periodDays)
        }
    }

    /// "monday brief" on Mondays (the landing framing), "brief" otherwise.
    static func headerTitle(now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.component(.weekday, from: now) == 2 ? "monday brief" : "brief"
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
                        accentWord: "done",
                        items: brief.ticketItems,
                        expanded: $ticketsExpanded)
                }
                if brief.decisionsSurfaced > 0 {
                    countRow(
                        brief.decisionsSurfaced,
                        "architectural decision\(brief.decisionsSurfaced == 1 ? "" : "s") surfaced")
                }
                if brief.blockersResolved > 0 {
                    countRow(
                        brief.blockersResolved,
                        "blocker\(brief.blockersResolved == 1 ? "" : "s") \(brief.blockerResolutionNote ?? "resolved")",
                        accentWord: brief.blockerResolutionNote)
                }
                if brief.commitsPushed > 0 {
                    countRow(brief.commitsPushed, "commits pushed")
                }
                if brief.reviewsAuthored > 0 {
                    countRow(brief.reviewsAuthored, "reviews authored")
                }

                LeafCardFooterLink(
                    note: brief.contributorCount > 1
                        ? "\(brief.contributorCount) contributors" : nil,
                    title: "read full brief"
                ) {
                    detailPresented = true
                }
            }
        }
    }

    /// Counter line; when `items` are provided the row toggles an inline
    /// detail list ("which PRs exactly") with a chevron affordance.
    @ViewBuilder
    private func countRow(
        _ count: Int, _ label: String, accentWord: String? = nil,
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
                HStack(alignment: .firstTextBaseline, spacing: LeafSpace.xs) {
                    LeafCountFigure(count: count, text: label, accentWord: accentWord)
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(LeafType.label)
                            .foregroundStyle(LeafColor.text.quaternary)
                            .rotationEffect(.degrees(expanded?.wrappedValue == true ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityLabel("\(count) \(label)\(canExpand ? ", tap to expand" : "")")

            if canExpand, expanded?.wrappedValue == true {
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    ForEach(items) { item in
                        BriefItemRow(item: item)
                    }
                }
                .padding(.leading, LeafSpace.xxl)
            }
        }
    }
}

/// One ref+title line, clickable when a source URL exists. Shared by the
/// inline expansion and the detail sheet.
struct BriefItemRow: View {
    let item: BriefItem

    var body: some View {
        Button {
            if let url = item.sourceURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: LeafSpace.xs) {
                Text(item.ref)
                    .font(LeafType.mono.small)
                    .foregroundStyle(LeafColor.status.success)
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

/// Track B3 — "read full brief →" destination: sectioned detail behind the
/// counters (PRs / tickets / decisions / blockers).
struct BriefDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let detail: BriefDetail
    let periodDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            LeafTerminalCardHeader(
                dotTone: .success,
                title: "full brief",
                detail: "last \(periodDays) days"
            )

            if detail.sections.isEmpty {
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "Nothing to expand yet.",
                    description: "Counters with detail land here."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LeafSpace.lg) {
                        ForEach(detail.sections) { section in
                            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                                Text(section.title)
                                    .leafSectionLabel()
                                    .foregroundStyle(LeafColor.text.tertiary)
                                ForEach(section.items) { item in
                                    BriefItemRow(item: item)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                LeafButton("Done", variant: .secondary) { dismiss() }
            }
        }
        .padding(LeafSpace.xl)
        .frame(minWidth: 460, minHeight: 380)
    }
}
