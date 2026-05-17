//
//  IDEsDetailScreen.swift
//  Track 7 P2 — Combined IDEs (VSCode-family + JetBrains + fallback
//  window-title) detail. Aggregates: per-IDE-family breakdown, top
//  workspaces, top files. Top sections only rendered when non-empty so
//  a JetBrains-only user doesn't see an empty VSCode block.
//

import SwiftUI
import LeafCore

struct IDEsDetailScreen: View {
    @State private var vm: IDEsDetailViewModel

    init(vm: IDEsDetailViewModel = IDEsDetailViewModel()) {
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
                title: "No IDE activity yet",
                description: "Once VSCode or a JetBrains IDE is active for this period, you'll see workspace and file breakdowns here."
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
        breakdown: IDEsActivityBreakdown,
        daily: [Double]
    ) -> some View {
        SurfaceDetailLayout(
            title: HomeSurface.ides.displayName,
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
    private func aggregates(breakdown: IDEsActivityBreakdown) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            perIDESection(breakdown: breakdown)
            if !breakdown.topWorkspaces.isEmpty {
                topWorkspacesSection(breakdown: breakdown)
            }
            if !breakdown.topFiles.isEmpty {
                topFilesSection(breakdown: breakdown)
            }
        }
    }

    private func perIDESection(breakdown: IDEsActivityBreakdown) -> some View {
        LeafSection(title: "Per-IDE breakdown") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    row(label: "VSCode family", value: "\(breakdown.vscodeFamilyEventCount)")
                    row(label: "JetBrains", value: "\(breakdown.jetbrainsEventCount)")
                    row(label: "Fallback titles", value: "\(breakdown.fallbackTitleCount)")
                }
            }
        }
    }

    private func topWorkspacesSection(breakdown: IDEsActivityBreakdown) -> some View {
        LeafSection(title: "Top workspaces") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(breakdown.topWorkspaces.prefix(5), id: \.self) { workspace in
                        Text(workspace)
                            .font(LeafType.mono.regular)
                            .foregroundStyle(LeafColor.text.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func topFilesSection(breakdown: IDEsActivityBreakdown) -> some View {
        LeafSection(title: "Top files") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(breakdown.topFiles.prefix(5), id: \.self) { file in
                        Text(file)
                            .font(LeafType.mono.regular)
                            .foregroundStyle(LeafColor.text.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
