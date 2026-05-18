//
//  LinearDetailScreen.swift
//  Track 7 P4 — Linear drill-down detail. Reuses SurfaceDetailLayout
//  (range tab + headline + chart placeholder + aggregates). NO scope drift
//  banner (Linear OAuth scope `read` фиксирован).
//
//  LinearActivityBreakdown.byProject uses `.project` key (not `.name`).
//  LinearActivityBreakdown.byStatus uses `.status` key (not `.name`).
//  LatencyStats fields: medianSeconds / avgSeconds / maxSeconds / sampleCount.
//  Transitions are embedded in breakdown.transitions (LinearTransitionBreakdown?).
//

import LeafCore
import SwiftUI

struct LinearDetailScreen: View {
    @State private var vm: LinearDetailViewModel

    init(vm: LinearDetailViewModel = LinearDetailViewModel()) {
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
            case .loaded(let headline, let breakdown):
                loadedContent(headline: headline, breakdown: breakdown)
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
                title: "No Linear activity yet",
                description: "Once you touch a Linear issue in this period, it'll show up here."
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
        breakdown: LinearActivityBreakdown
    ) -> some View {
        SurfaceDetailLayout(
            title: LayerBProvider.linear.displayName,
            range: Binding(get: { vm.range }, set: { vm.range = $0 }),
            headline: headline,
            chart: { chartPlaceholder },
            aggregates: { aggregates(breakdown: breakdown) }
        )
    }

    // MARK: - Chart slot

    private var chartPlaceholder: some View {
        Text("Daily breakdown will appear here.")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Aggregates

    @ViewBuilder
    private func aggregates(breakdown: LinearActivityBreakdown) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            activitySection(breakdown: breakdown)
            if let transitions = breakdown.transitions, transitions.total > 0 {
                transitionsSection(transitions: transitions)
            }
            if !breakdown.byProject.isEmpty {
                topProjectsSection(breakdown: breakdown)
            }
            if !breakdown.byStatus.isEmpty {
                topStatusSection(breakdown: breakdown)
            }
            if let stats = breakdown.completionDurationStats {
                completionDurationSection(stats: stats)
            }
        }
    }

    // MARK: - Sections

    private func activitySection(breakdown: LinearActivityBreakdown) -> some View {
        LeafSection(title: "Activity") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    statRow(label: "Issues touched", value: "\(breakdown.issuesTouched)")
                    if let wow = breakdown.wowDeltaPct {
                        statRow(label: "Week-over-week", value: formatWow(wow))
                    }
                    if let streak = breakdown.issueCloseStreak, streak > 0 {
                        statRow(label: "Close streak", value: "\(streak)-day")
                    }
                }
            }
        }
    }

    private func transitionsSection(transitions: LinearTransitionBreakdown) -> some View {
        LeafSection(title: "Transitions") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    if transitions.started > 0 {
                        statRow(label: "Started", value: "\(transitions.started)")
                    }
                    if transitions.completed > 0 {
                        statRow(label: "Completed", value: "\(transitions.completed)")
                    }
                    if transitions.canceled > 0 {
                        statRow(label: "Canceled", value: "\(transitions.canceled)")
                    }
                    if transitions.reopened > 0 {
                        statRow(label: "Reopened", value: "\(transitions.reopened)")
                    }
                }
            }
        }
    }

    private func topProjectsSection(breakdown: LinearActivityBreakdown) -> some View {
        LeafSection(title: "Top projects") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(breakdown.byProject.prefix(5), id: \.project) { entry in
                        HStack {
                            Text(entry.project)
                                .font(LeafType.body.regular)
                                .foregroundStyle(LeafColor.text.primary)
                            Spacer()
                            Text("\(entry.count)")
                                .font(LeafType.mono.regular)
                                .foregroundStyle(LeafColor.text.secondary)
                        }
                    }
                }
            }
        }
    }

    private func topStatusSection(breakdown: LinearActivityBreakdown) -> some View {
        LeafSection(title: "Top status") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(breakdown.byStatus.prefix(5), id: \.status) { entry in
                        HStack {
                            Text(entry.status)
                                .font(LeafType.body.regular)
                                .foregroundStyle(LeafColor.text.primary)
                            Spacer()
                            Text("\(entry.count)")
                                .font(LeafType.mono.regular)
                                .foregroundStyle(LeafColor.text.secondary)
                        }
                    }
                }
            }
        }
    }

    private func completionDurationSection(stats: LatencyStats) -> some View {
        LeafSection(title: "Completion duration") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    statRow(label: "Median", value: formatDuration(Double(stats.medianSeconds)))
                    statRow(label: "Average", value: formatDuration(Double(stats.avgSeconds)))
                    statRow(label: "Maximum", value: formatDuration(Double(stats.maxSeconds)))
                    statRow(label: "Sample", value: "\(stats.sampleCount)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
            Spacer()
            Text(value)
                .font(LeafType.mono.regular)
                .foregroundStyle(LeafColor.text.primary)
        }
    }

    private func formatWow(_ delta: Double) -> String {
        let pct = Int((delta * 100).rounded())
        return pct >= 0 ? "+\(pct)%" : "−\(abs(pct))%"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let days = seconds / 86400
        if days >= 1 {
            return String(format: "%.1fd", days)
        }
        let hours = seconds / 3600
        if hours >= 1 {
            return String(format: "%.1fh", hours)
        }
        return String(format: "%.0fm", seconds / 60)
    }
}
