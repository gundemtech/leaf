// Leaf/Views/Window/SurfaceDetail/LayerB/GitHubDetailScreen.swift
//
//  GitHubDetailScreen.swift
//  Track 7 P4 — GitHub drill-down detail. Reuses SurfaceDetailLayout +
//  sticky scope-drift reauth banner outside ScrollView when
//  GitHubScopesReader.state == .connectedScopeOutdated AND dismiss flag not set.
//
//  Field adaptations vs plan:
//  - EventKindCountEntry.eventKind (not .kind) — id: \.eventKind, entry.eventKind
//  - LatencyStats.medianSeconds / .avgSeconds / .maxSeconds (Int) — Double() cast

import SwiftUI
import LeafCore

struct GitHubDetailScreen: View {
    @State private var vm: GitHubDetailViewModel
    @Environment(GitHubScopesReader.self) private var scopesReader
    @Environment(GitHubOAuthService.self) private var githubOAuth

    init(vm: GitHubDetailViewModel = GitHubDetailViewModel()) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        Group {
            switch vm.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                emptyContent
            case .error(let message):
                errorBanner(message)
            case .loaded(let headline, let breakdown, let reviewActivity):
                loadedContent(headline: headline, breakdown: breakdown, reviewActivity: reviewActivity)
            }
        }
        .onAppear { vm.reload() }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeDriftBannerIfNeeded
            VStack {
                Spacer()
                LeafEmptyState(
                    icon: LeafIcons.brand.leaf,
                    title: "No GitHub activity yet",
                    description: "Once you push commits, open PRs, or review code in this period, it'll show up here."
                )
                Spacer()
            }
            .frame(minHeight: LeafEmptyStateTokens.centeredMinHeight)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack {
            LeafBanner(tone: .danger, title: message)
            Spacer()
        }
        .padding(LeafSpace.xxl)
    }

    @ViewBuilder
    private func loadedContent(
        headline: DetailHeadline,
        breakdown: GitHubActivityBreakdown,
        reviewActivity: ReviewActivityResult?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeDriftBannerIfNeeded
            SurfaceDetailLayout(
                title: LayerBProvider.github.displayName,
                range: Binding(get: { vm.range }, set: { vm.range = $0 }),
                headline: headline,
                chart: { chartPlaceholder },
                aggregates: { aggregates(breakdown: breakdown, reviewActivity: reviewActivity) }
            )
        }
    }

    @ViewBuilder
    private var scopeDriftBannerIfNeeded: some View {
        if case .connectedScopeOutdated(let missing) = scopesReader.state, !vm.scopeBannerDismissed {
            LeafBanner(
                tone: .warning,
                title: "GitHub permissions need a refresh",
                description: "\(missing.count) new event type\(missing.count == 1 ? "" : "s") \(missing.count == 1 ? "is" : "are") blocked until you re-authorize.",
                ctaTitle: "Re-authorize",
                onCTA: {
                    Task { await githubOAuth.connect(scopes: GitHubScopesService.requested()) }
                },
                onDismiss: {
                    vm.scopeBannerDismissed = true
                }
            )
            .padding(.horizontal, LeafSpace.xxl)
            .padding(.top, LeafSpace.md)
        }
    }

    private var chartPlaceholder: some View {
        Text("Daily breakdown will appear here.")
            .font(LeafType.body.small)
            .foregroundStyle(LeafColor.text.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func aggregates(
        breakdown: GitHubActivityBreakdown,
        reviewActivity: ReviewActivityResult?
    ) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            activitySection(breakdown: breakdown)
            if let stats = breakdown.prCycleStats {
                prCycleSection(stats: stats)
            }
            if let r = reviewActivity, r.reviewsSubmittedCount + r.reviewCommentsCount + r.reviewThreadResolvedCount > 0 {
                reviewActivitySection(result: r)
            }
            if let stats = breakdown.reviewDelayStats {
                reviewDelaySection(stats: stats)
            }
            if !breakdown.byRepo.isEmpty {
                topReposSection(breakdown: breakdown)
            }
            if !breakdown.byEventKind.isEmpty {
                byEventKindSection(breakdown: breakdown)
            }
            if let r = reviewActivity, !r.linkedPRs.isEmpty {
                linkedPRsSection(result: r)
            }
        }
    }

    private func activitySection(breakdown: GitHubActivityBreakdown) -> some View {
        LeafSection(title: "Activity") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    statRow(label: "Events", value: "\(breakdown.eventsCount)")
                    if let wow = breakdown.wowDeltaPct {
                        statRow(label: "Week-over-week", value: formatWow(wow))
                    }
                    if let streak = breakdown.commitStreak, streak > 0 {
                        statRow(label: "Commit streak", value: "\(streak)-day")
                    }
                }
            }
        }
    }

    private func prCycleSection(stats: LatencyStats) -> some View {
        LeafSection(title: "PR cycle") {
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

    private func reviewActivitySection(result: ReviewActivityResult) -> some View {
        LeafSection(title: "Review activity") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    statRow(label: "Reviews submitted", value: "\(result.reviewsSubmittedCount)")
                    statRow(label: "Review comments", value: "\(result.reviewCommentsCount)")
                    statRow(label: "Threads resolved", value: "\(result.reviewThreadResolvedCount)")
                }
            }
        }
    }

    private func reviewDelaySection(stats: LatencyStats) -> some View {
        LeafSection(title: "Review delay") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    statRow(label: "Median", value: formatDuration(Double(stats.medianSeconds)))
                    statRow(label: "Average", value: formatDuration(Double(stats.avgSeconds)))
                    statRow(label: "Maximum", value: formatDuration(Double(stats.maxSeconds)))
                }
            }
        }
    }

    private func topReposSection(breakdown: GitHubActivityBreakdown) -> some View {
        LeafSection(title: "Top repos") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(breakdown.byRepo.prefix(5), id: \.repo) { entry in
                        HStack {
                            Text(entry.repo)
                                .font(LeafType.body.regular)
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

    private func byEventKindSection(breakdown: GitHubActivityBreakdown) -> some View {
        LeafSection(title: "By event kind") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    // EventKindCountEntry uses .eventKind (not .kind per plan)
                    ForEach(breakdown.byEventKind.prefix(5), id: \.eventKind) { entry in
                        HStack {
                            Text(humanize(entry.eventKind))
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

    private func linkedPRsSection(result: ReviewActivityResult) -> some View {
        LeafSection(title: "Linked PRs") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    ForEach(result.linkedPRs.prefix(10), id: \.self) { entry in
                        HStack {
                            Text("\(entry.repo) #\(entry.prNumber)")
                                .font(LeafType.body.regular)
                                .foregroundStyle(LeafColor.text.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let lid = entry.linkedLinearID {
                                Text("→ \(lid)")
                                    .font(LeafType.mono.regular)
                                    .foregroundStyle(LeafColor.text.secondary)
                            }
                        }
                    }
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
        } else {
            let hours = seconds / 3600
            return hours >= 1 ? String(format: "%.1fh", hours) : String(format: "%.0fm", seconds / 60)
        }
    }

    private func humanize(_ snake: String) -> String {
        snake.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
