import SwiftUI
import LeafCore

/// Phase 4.10.A — three glass cards (Linear / GitHub / Slack) below the
/// existing Home metric grid. Each card surfaces the per-provider breakdown
/// already living in `InsightsSnapshot` after Phases 4.2–4.7 — counts, top
/// projects/repos/channels, transitions, latency stats, streaks. Cards
/// degrade gracefully when a provider is empty (not connected / no events).
struct ProvidersBlock: View {
    let snapshot: InsightsSnapshot

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280), spacing: 16)],
            spacing: 16
        ) {
            LinearCard(snapshot: snapshot)
            GitHubCard(snapshot: snapshot)
            SlackCard(snapshot: snapshot)
        }
    }
}

// MARK: - Linear

private struct LinearCard: View {
    let snapshot: InsightsSnapshot

    var body: some View {
        ProviderCard(title: "LINEAR · TODAY") {
            if isEmpty {
                EmptyHint(text: "No Linear activity yet today.")
            } else {
                if snapshot.linearIssuesTouched > 0 {
                    StatLine(label: "Issues touched", value: "\(snapshot.linearIssuesTouched)")
                }
                if let transitions = snapshot.linearTransitions, transitions.total > 0 {
                    HStack(spacing: 10) {
                        TransitionDot(label: "Started", count: transitions.started)
                        TransitionDot(label: "Done", count: transitions.completed)
                        if transitions.canceled > 0 {
                            TransitionDot(label: "Cancel", count: transitions.canceled)
                        }
                        if transitions.reopened > 0 {
                            TransitionDot(label: "Reopen", count: transitions.reopened)
                        }
                        Spacer()
                    }
                }
                if let rate = snapshot.linearCompletionRate {
                    StatLine(label: "Follow-through", value: String(format: "%.0f%%", rate * 100))
                }
                if !snapshot.linearByProject.isEmpty {
                    BulletList(
                        title: "Top projects",
                        items: snapshot.linearByProject.prefix(3).map {
                            "\($0.project) · \($0.count)"
                        }
                    )
                }
                if !snapshot.linearByStatus.isEmpty {
                    BulletList(
                        title: "By status",
                        items: snapshot.linearByStatus.prefix(3).map {
                            "\($0.status) · \($0.count)"
                        }
                    )
                }
                if snapshot.linearIssueCloseStreak >= 3 {
                    StreakLine(emoji: "🔥", text: "\(snapshot.linearIssueCloseStreak)-day close streak")
                }
            }
        }
    }

    private var isEmpty: Bool {
        snapshot.linearIssuesTouched == 0
            && (snapshot.linearTransitions?.total ?? 0) == 0
            && snapshot.linearByProject.isEmpty
            && snapshot.linearByStatus.isEmpty
    }
}

// MARK: - GitHub

private struct GitHubCard: View {
    let snapshot: InsightsSnapshot

    var body: some View {
        ProviderCard(title: "GITHUB · TODAY") {
            if isEmpty {
                EmptyHint(text: "No GitHub activity yet today.")
            } else {
                if snapshot.githubEventsCount > 0 {
                    StatLine(label: "Events", value: "\(snapshot.githubEventsCount)")
                }
                if !snapshot.githubByEventKind.isEmpty {
                    BulletList(
                        title: "Breakdown",
                        items: snapshot.githubByEventKind.prefix(4).map {
                            "\(humanize($0.eventKind)) · \($0.count)"
                        }
                    )
                }
                if !snapshot.githubByRepo.isEmpty {
                    BulletList(
                        title: "Top repos",
                        items: snapshot.githubByRepo.prefix(3).map {
                            "\($0.repo) · \($0.count)"
                        }
                    )
                }
                if let stats = snapshot.githubPRCycleStats, stats.sampleCount > 0 {
                    StatLine(
                        label: "PR cycle (median)",
                        value: durationLabel(TimeInterval(stats.medianSeconds))
                    )
                }
                if let stats = snapshot.githubReviewDelayStats, stats.sampleCount > 0 {
                    StatLine(
                        label: "Review delay (median)",
                        value: durationLabel(TimeInterval(stats.medianSeconds))
                    )
                }
                if snapshot.githubCommitStreak >= 3 {
                    StreakLine(emoji: "🔥", text: "\(snapshot.githubCommitStreak)-day commit streak")
                }
            }
        }
    }

    private var isEmpty: Bool {
        snapshot.githubEventsCount == 0
            && snapshot.githubByRepo.isEmpty
            && snapshot.githubByEventKind.isEmpty
    }

    private func humanize(_ eventKind: String) -> String {
        eventKind
            .replacingOccurrences(of: "_", with: " ")
            .capitalized(with: nil)
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return String(format: "%.1fh", seconds / 3600) }
        return String(format: "%.1fd", seconds / 86_400)
    }
}

// MARK: - Slack

private struct SlackCard: View {
    let snapshot: InsightsSnapshot

    var body: some View {
        ProviderCard(title: "SLACK · TODAY") {
            if isEmpty {
                EmptyHint(text: "No Slack activity yet today.")
            } else {
                if snapshot.slackMessagesCount > 0 {
                    StatLine(label: "Messages", value: "\(snapshot.slackMessagesCount)")
                }
                if snapshot.slackHuddleMinutes > 0 {
                    StatLine(label: "Huddle time", value: "\(snapshot.slackHuddleMinutes)m")
                }
                if snapshot.slackReactionsReceived > 0 {
                    StatLine(label: "Reactions", value: "\(snapshot.slackReactionsReceived)")
                }
                if !snapshot.slackByChannel.isEmpty {
                    BulletList(
                        title: "Top channels",
                        items: snapshot.slackByChannel.prefix(3).map {
                            "\($0.channelName) · \($0.count)"
                        }
                    )
                }
                if snapshot.slackHuddleParticipationStreak >= 3 {
                    StreakLine(emoji: "🎙", text: "\(snapshot.slackHuddleParticipationStreak)-day huddle streak")
                }
            }
        }
    }

    private var isEmpty: Bool {
        snapshot.slackMessagesCount == 0
            && snapshot.slackHuddleMinutes == 0
            && snapshot.slackByChannel.isEmpty
    }
}

// MARK: - Shared building blocks

private struct ProviderCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .leafLabelStyle()
                content()
            }
        }
    }
}

private struct StatLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.leafBody)
                .foregroundStyle(.leafInk)
            Spacer()
            Text(value)
                .font(.leafBody.monospacedDigit())
                .foregroundStyle(.leafMuted)
        }
    }
}

private struct BulletList: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.leafCaption)
                .foregroundStyle(.leafMuted)
                .kerning(0.6)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.leafBody)
                    .foregroundStyle(.leafInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

private struct TransitionDot: View {
    let label: String
    let count: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.leafBody.monospacedDigit())
                .foregroundStyle(.leafInk)
            Text(label)
                .font(.leafCaption)
                .foregroundStyle(.leafMuted)
        }
    }
}

private struct StreakLine: View {
    let emoji: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(emoji).font(.leafBody)
            Text(text)
                .font(.leafCaption)
                .foregroundStyle(.leafMuted)
        }
    }
}

private struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.leafBody)
            .foregroundStyle(.leafMuted)
    }
}
