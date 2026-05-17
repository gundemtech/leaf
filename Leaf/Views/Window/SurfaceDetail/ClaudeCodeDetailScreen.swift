//
//  ClaudeCodeDetailScreen.swift
//  Track 7 P1 — Claude Code detail (vertical-slice template).
//  Reuses SurfaceDetailLayout; aggregates section surfaces session count /
//  top tools / top projects from AIActivityBreakdown. Recent events list
//  is deferred to P11 polish — this screen renders headline + aggregates
//  + empty/error states in P1.
//

import SwiftUI
import LeafCore

struct ClaudeCodeDetailScreen: View {
    @State private var vm: ClaudeCodeDetailViewModel

    init(vm: ClaudeCodeDetailViewModel = ClaudeCodeDetailViewModel()) {
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
                title: "No Claude Code activity yet",
                description: "Once Claude Code captures activity for this period, you'll see session counts, top tools, and project breakdowns here."
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
        breakdown: AIActivityBreakdown,
        daily: [Double]
    ) -> some View {
        SurfaceDetailLayout(
            title: HomeSurface.claudeCode.displayName,
            range: Binding(get: { vm.range }, set: { vm.range = $0 }),
            headline: headline,
            chart: { chartSlot(daily: daily) },
            aggregates: { aggregates(breakdown: breakdown) }
        )
    }

    // MARK: - Chart slot

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
    private func aggregates(breakdown: AIActivityBreakdown) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            sessionsSection(breakdown: breakdown)
            if !breakdown.topTools.isEmpty {
                topToolsSection(breakdown: breakdown)
            }
            if !breakdown.topProjects.isEmpty {
                topProjectsSection(breakdown: breakdown)
            }
        }
    }

    private func sessionsSection(breakdown: AIActivityBreakdown) -> some View {
        LeafSection(title: "Sessions") {
            LeafCard(padding: .regular) {
                Text("\(breakdown.sessionCount) session\(breakdown.sessionCount == 1 ? "" : "s")")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
            }
        }
    }

    private func topToolsSection(breakdown: AIActivityBreakdown) -> some View {
        LeafSection(title: "Top tools") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(breakdown.topTools.prefix(5), id: \.name) { entry in
                        HStack {
                            Text(entry.name)
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

    private func topProjectsSection(breakdown: AIActivityBreakdown) -> some View {
        LeafSection(title: "Top projects") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(breakdown.topProjects.prefix(3), id: \.cwd) { entry in
                        HStack {
                            Text(entry.cwd)
                                .font(LeafType.body.regular)
                                .foregroundStyle(LeafColor.text.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(formatMinutes(entry.aiActiveSeconds))
                                .font(LeafType.mono.regular)
                                .foregroundStyle(LeafColor.text.secondary)
                        }
                    }
                }
            }
        }
    }

    private func formatMinutes(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return "\(m)m"
    }
}
