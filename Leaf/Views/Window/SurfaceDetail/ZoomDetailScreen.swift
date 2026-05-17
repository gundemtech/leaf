//
//  ZoomDetailScreen.swift
//  Track 7 P2 — Zoom meeting detail. Aggregates: meeting totals
//  (count + total duration), calendar linkage (linked vs ad-hoc), longest
//  meeting (rendered only when longestMeetingSeconds > 0). Reuses
//  ZoomDetailViewModel.formatHours for duration rendering.
//

import SwiftUI
import LeafCore

struct ZoomDetailScreen: View {
    @State private var vm: ZoomDetailViewModel

    init(vm: ZoomDetailViewModel = ZoomDetailViewModel()) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                emptyState
            case .error(let message):
                errorBanner(message)
            case .loaded(let headline, let breakdown, let daily):
                loadedContent(headline: headline, breakdown: breakdown, daily: daily)
            }
        }
        .onAppear { vm.reload() }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack {
            Spacer()
            LeafEmptyState(
                icon: LeafIcons.brand.leaf,
                title: "No Zoom activity yet",
                description: "Once you have a Zoom meeting in this period, you'll see meeting totals, calendar linkage, and your longest call here."
            )
            Spacer()
        }
        .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        VStack {
            LeafBanner(tone: .danger, title: message)
            Spacer()
        }
        .padding(LeafSpace.xxl)
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loadedContent(
        headline: DetailHeadline,
        breakdown: ZoomActivityBreakdown,
        daily: [Double]
    ) -> some View {
        SurfaceDetailLayout(
            title: HomeSurface.zoom.displayName,
            range: Binding(get: { vm.range }, set: { vm.range = $0 }),
            headline: headline,
            chart: { chartSlot(daily: daily) },
            aggregates: { aggregates(breakdown: breakdown) }
        )
    }

    @ViewBuilder
    private func chartSlot(daily: [Double]) -> some View {
        if daily.isEmpty {
            Text("Daily breakdown will appear here.")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LeafSparkline(values: daily)
        }
    }

    // MARK: - Aggregates

    @ViewBuilder
    private func aggregates(breakdown: ZoomActivityBreakdown) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            meetingTotalsSection(breakdown: breakdown)
            calendarLinkageSection(breakdown: breakdown)
            if breakdown.longestMeetingSeconds > 0 {
                longestMeetingSection(breakdown: breakdown)
            }
        }
    }

    private func meetingTotalsSection(breakdown: ZoomActivityBreakdown) -> some View {
        LeafSection(title: "Meeting totals") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    row(label: "Meetings",
                        value: "\(breakdown.meetingCount)")
                    row(label: "Total time",
                        value: ZoomDetailViewModel.formatHours(breakdown.totalDurationSeconds))
                }
            }
        }
    }

    private func calendarLinkageSection(breakdown: ZoomActivityBreakdown) -> some View {
        let adHoc = max(0, breakdown.meetingCount - breakdown.calendarLinkedCount)
        return LeafSection(title: "Calendar linkage") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    row(label: "Linked", value: "\(breakdown.calendarLinkedCount)")
                    if adHoc > 0 {
                        row(label: "Ad-hoc", value: "\(adHoc)")
                    }
                }
            }
        }
    }

    private func longestMeetingSection(breakdown: ZoomActivityBreakdown) -> some View {
        LeafSection(title: "Longest meeting") {
            LeafCard(padding: .regular) {
                Text("\(ZoomDetailViewModel.formatHours(breakdown.longestMeetingSeconds)) · longest")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Spacer()
            Text(value)
                .font(LeafType.mono.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }
}
