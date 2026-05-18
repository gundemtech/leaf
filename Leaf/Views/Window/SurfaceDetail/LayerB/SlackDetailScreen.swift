// Leaf/Views/Window/SurfaceDetail/LayerB/SlackDetailScreen.swift
//
//  SlackDetailScreen.swift
//  Track 7 P4 — Slack drill-down detail. Reuses SurfaceDetailLayout +
//  sticky scope-drift reauth banner outside ScrollView when
//  SlackScopesReader.state == .connectedScopeOutdated AND dismiss flag not set.
//
//  Field adaptations vs plan:
//  - ChannelCountEntry.channelName (not .name) — id: \.channelName, entry.channelName
//  - LatencyStats.medianSeconds / .avgSeconds / .maxSeconds (Int) — Double() cast
//    (plan used stats.median / .average / .maximum which don't exist on LatencyStats)

import LeafCore
import SwiftUI

struct SlackDetailScreen: View {
    @State private var vm: SlackDetailViewModel
    @Environment(SlackScopesReader.self) private var scopesReader
    @Environment(SlackOAuthService.self) private var slackOAuth

    init(vm: SlackDetailViewModel = SlackDetailViewModel()) {
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
            case .loaded(let headline, let breakdown):
                loadedContent(headline: headline, breakdown: breakdown)
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
                    title: "No Slack activity yet",
                    description: "Once you send messages or join huddles in this period, it'll show up here."
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
    private func loadedContent(headline: DetailHeadline, breakdown: SlackActivityBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeDriftBannerIfNeeded
            SurfaceDetailLayout(
                title: LayerBProvider.slack.displayName,
                range: Binding(get: { vm.range }, set: { vm.range = $0 }),
                headline: headline,
                chart: { chartPlaceholder },
                aggregates: { aggregates(breakdown: breakdown) }
            )
        }
    }

    @ViewBuilder
    private var scopeDriftBannerIfNeeded: some View {
        if case .connectedScopeOutdated(let missing) = scopesReader.state, !vm.scopeBannerDismissed {
            LeafBanner(
                tone: .warning,
                title: "Slack permissions need a refresh",
                description:
                    "\(missing.count) new event type\(missing.count == 1 ? "" : "s") \(missing.count == 1 ? "is" : "are") blocked until you re-authorize.",
                ctaTitle: "Re-authorize Slack",
                onCTA: {
                    Task { await slackOAuth.connect() }
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
    private func aggregates(breakdown: SlackActivityBreakdown) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            activitySection(breakdown: breakdown)
            if breakdown.huddleMinutes > 0 {
                huddleSection(breakdown: breakdown)
            }
            if !breakdown.byChannel.isEmpty {
                topChannelsSection(breakdown: breakdown)
            }
        }
    }

    private func activitySection(breakdown: SlackActivityBreakdown) -> some View {
        LeafSection(title: "Activity") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    statRow(label: "Messages", value: "\(breakdown.messagesCount)")
                    if let wow = breakdown.wowDeltaPct {
                        statRow(label: "Week-over-week", value: formatWow(wow))
                    }
                    if let reactions = breakdown.reactionsReceived, reactions > 0 {
                        statRow(label: "Reactions received", value: "\(reactions)")
                    }
                    if let streak = breakdown.huddleParticipationStreak, streak > 0 {
                        statRow(label: "Huddle streak", value: "\(streak)-day")
                    }
                }
            }
        }
    }

    private func huddleSection(breakdown: SlackActivityBreakdown) -> some View {
        LeafSection(title: "Huddle") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    statRow(label: "Total minutes", value: "\(breakdown.huddleMinutes)m")
                    if let stats = breakdown.huddleSessionStats {
                        // LatencyStats stores Int seconds — cast to Double for formatDuration
                        statRow(label: "Median session", value: formatDuration(Double(stats.medianSeconds)))
                        statRow(label: "Average session", value: formatDuration(Double(stats.avgSeconds)))
                        statRow(label: "Longest session", value: formatDuration(Double(stats.maxSeconds)))
                        statRow(label: "Sample", value: "\(stats.sampleCount)")
                    }
                }
            }
        }
    }

    private func topChannelsSection(breakdown: SlackActivityBreakdown) -> some View {
        LeafSection(title: "Top channels") {
            LeafCard(padding: .regular) {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    // ChannelCountEntry uses .channelName (not .name per plan)
                    ForEach(breakdown.byChannel.prefix(5), id: \.channelName) { entry in
                        HStack {
                            Text(entry.channelName)
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
        let mins = Int(seconds / 60)
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(mins)m"
    }
}
