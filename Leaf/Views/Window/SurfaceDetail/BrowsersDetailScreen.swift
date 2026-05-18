//
//  BrowsersDetailScreen.swift
//  Track 7 P2 — Browsers detail (Safari + Chrome + Arc, allow-listed
//  domains only). Aggregates: per-browser page + activation counts, top
//  domains, bookmark deltas (rendered only when non-zero).
//

import LeafCore
import SwiftUI

struct BrowsersDetailScreen: View {
    @State private var vm: BrowsersDetailViewModel

    init(vm: BrowsersDetailViewModel = BrowsersDetailViewModel()) {
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
                title: "No browser activity yet",
                description:
                    "Once you visit an allow-listed domain in Safari, Chrome, or Arc, you'll see navigation and top-domain breakdowns here."
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
        breakdown: BrowsersActivityBreakdown,
        daily: [Double]
    ) -> some View {
        SurfaceDetailLayout(
            title: HomeSurface.browsers.displayName,
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
    private func aggregates(breakdown: BrowsersActivityBreakdown) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            perBrowserSection(breakdown: breakdown)
            if !breakdown.topDomains.isEmpty {
                topDomainsSection(breakdown: breakdown)
            }
            if breakdown.bookmarkEventCount > 0 {
                bookmarkDeltasSection(breakdown: breakdown)
            }
        }
    }

    private func perBrowserSection(breakdown: BrowsersActivityBreakdown) -> some View {
        LeafSection(title: "Per-browser breakdown") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    browserRow(
                        name: "Safari",
                        pages: breakdown.safariPageCount,
                        activations: breakdown.safariActivationCount)
                    browserRow(
                        name: "Chrome",
                        pages: breakdown.chromePageCount,
                        activations: breakdown.chromeActivationCount)
                    browserRow(
                        name: "Arc",
                        pages: breakdown.arcPageCount,
                        activations: breakdown.arcActivationCount)
                }
            }
        }
    }

    private func browserRow(name: String, pages: Int, activations: Int) -> some View {
        HStack {
            Text(name)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Spacer()
            Text("\(pages) page\(pages == 1 ? "" : "s") · \(activations) activation\(activations == 1 ? "" : "s")")
                .font(LeafType.mono.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private func topDomainsSection(breakdown: BrowsersActivityBreakdown) -> some View {
        LeafSection(title: "Top domains") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(breakdown.topDomains.prefix(5), id: \.domain) { entry in
                        HStack {
                            Text(entry.domain)
                                .font(LeafType.mono.regular)
                                .foregroundStyle(LeafColor.text.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
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

    private func bookmarkDeltasSection(breakdown: BrowsersActivityBreakdown) -> some View {
        LeafSection(title: "Bookmark deltas") {
            LeafCard(padding: .regular) {
                Text("\(breakdown.bookmarkEventCount) bookmark event\(breakdown.bookmarkEventCount == 1 ? "" : "s")")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
            }
        }
    }
}
