//
//  XcodeDetailScreen.swift
//  Track 7 P2 — Xcode surface detail. Mirrors ClaudeCodeDetailScreen
//  structure (state-switch over VM.state, SurfaceDetailLayout for the
//  loaded path). Aggregates: builds (success/fail), tests (pass/fail
//  when present), schemes & destinations (rendered only when non-empty).
//

import LeafCore
import SwiftUI

struct XcodeDetailScreen: View {
    @State private var vm: XcodeDetailViewModel

    init(vm: XcodeDetailViewModel = XcodeDetailViewModel()) {
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
                title: "No Xcode activity yet",
                description:
                    "Once Xcode captures activity for this period, you'll see build and test counts, success/failure splits, and your top schemes here."
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
        breakdown: XcodeActivityBreakdown,
        daily: [Double]
    ) -> some View {
        SurfaceDetailLayout(
            title: HomeSurface.xcode.displayName,
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
    private func aggregates(breakdown: XcodeActivityBreakdown) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            buildsSection(breakdown: breakdown)
            if breakdown.testRunCount > 0 {
                testsSection(breakdown: breakdown)
            }
            if !breakdown.topSchemes.isEmpty || !breakdown.topDestinations.isEmpty {
                schemesAndDestinationsSection(breakdown: breakdown)
            }
        }
    }

    private func buildsSection(breakdown: XcodeActivityBreakdown) -> some View {
        LeafSection(title: "Builds") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    row(label: "Successful", value: "\(breakdown.buildSuccessCount)")
                    row(label: "Failed", value: "\(breakdown.buildFailureCount)")
                }
            }
        }
    }

    private func testsSection(breakdown: XcodeActivityBreakdown) -> some View {
        LeafSection(title: "Tests") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    row(label: "Runs", value: "\(breakdown.testRunCount)")
                    if breakdown.testPassCount > 0 {
                        row(label: "Passed", value: "\(breakdown.testPassCount)")
                    }
                    if breakdown.testFailCount > 0 {
                        row(label: "Failed", value: "\(breakdown.testFailCount)")
                    }
                }
            }
        }
    }

    private func schemesAndDestinationsSection(breakdown: XcodeActivityBreakdown) -> some View {
        LeafSection(title: "Schemes & destinations") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.md) {
                    if !breakdown.topSchemes.isEmpty {
                        VStack(alignment: .leading, spacing: LeafSpace.xs) {
                            Text("Schemes")
                                .font(LeafType.body.small)
                                .foregroundStyle(LeafColor.text.tertiary)
                            ForEach(breakdown.topSchemes.prefix(5), id: \.self) { scheme in
                                Text(scheme)
                                    .font(LeafType.mono.regular)
                                    .foregroundStyle(LeafColor.text.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    if !breakdown.topDestinations.isEmpty {
                        VStack(alignment: .leading, spacing: LeafSpace.xs) {
                            Text("Destinations")
                                .font(LeafType.body.small)
                                .foregroundStyle(LeafColor.text.tertiary)
                            ForEach(breakdown.topDestinations.prefix(5), id: \.self) { dest in
                                Text(dest)
                                    .font(LeafType.mono.regular)
                                    .foregroundStyle(LeafColor.text.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
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
