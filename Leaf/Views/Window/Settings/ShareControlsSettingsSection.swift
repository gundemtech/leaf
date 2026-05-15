//
//  ShareControlsSettingsSection.swift
//  Leaf
//
//  Track 5 / S5 — Share Controls UI section in Settings. Renders 9 per-source
//  toggles + Never Shared read-only card. Binds to ShareRulesReader.
//

import SwiftUI
import LeafCore

struct ShareControlsSettingsSection: View {
    @Environment(ShareRulesReader.self) private var reader

    var body: some View {
        LeafSection(
            title: "Share Controls",
            description: "Per-source toggles. Off by default for everything except commits, Linear issues, and detected decisions/blockers. Teammates only see what you explicitly turn on."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                ForEach(ShareSource.allCases, id: \.rawValue) { source in
                    ShareSourceRow(source: source, isEnabled: isEnabled(source))
                }
                NeverSharedCard()
            }
        }
        .onAppear { reader.refresh() }
    }

    private func isEnabled(_ source: ShareSource) -> Bool {
        if case .loaded(let rules) = reader.state {
            return rules[source] ?? ShareRuleDefaults.isEnabledByDefault(source)
        }
        return ShareRuleDefaults.isEnabledByDefault(source)
    }
}

private struct ShareSourceRow: View {
    @Environment(ShareRulesReader.self) private var reader
    let source: ShareSource
    let isEnabled: Bool

    var body: some View {
        LeafCard(variant: .raised, padding: .regular) {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                Image(systemName: source.sfSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(LeafColor.text.secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(source.displayName)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                    Text(source.explainer)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { reader.setEnabled(source, enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LeafColor.accent.primary)
            }
        }
    }
}

private struct NeverSharedCard: View {
    var body: some View {
        LeafCard(variant: .glass, padding: .regular) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                HStack(spacing: LeafSpace.xs) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LeafColor.text.secondary)
                    Text("Never shared")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                }
                Text("Regardless of toggles above, the following are never transmitted:")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                ForEach(NeverSharedItem.all, id: \.title) { item in
                    HStack(alignment: .firstTextBaseline, spacing: LeafSpace.xs) {
                        Text("•").foregroundStyle(LeafColor.text.tertiary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title)
                                .font(LeafType.body.small)
                                .foregroundStyle(LeafColor.text.primary)
                            Text(item.description)
                                .font(LeafType.body.small)
                                .foregroundStyle(LeafColor.text.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct NeverSharedItem {
    let title: String
    let description: String

    static let all: [NeverSharedItem] = [
        .init(title: "Secrets-bearing files", description: ".env*, .git/config, .aws/credentials, .ssh/"),
        .init(title: "Large files", description: "Anything over 100 MB"),
        .init(title: "AI prompts and responses", description: "Conversation content with Claude, Cursor, and other AI assistants"),
        .init(title: "Personal apps", description: "Signal, Messages, Discord, Spotify — not in default deny-list but always opt-in"),
    ]
}

// MARK: - ShareSource display extensions (UI-only, S5)

extension ShareSource {
    var displayName: String {
        switch self {
        case .gitCommits:            return "Git commits"
        case .linearIssues:          return "Linear issues"
        case .slackMentions:         return "Slack mentions"
        case .githubPRs:             return "GitHub PRs"
        case .detectedDecisions:     return "Detected decisions"
        case .detectedBlockers:      return "Detected blockers"
        case .detectedOpenQuestions: return "Detected open questions"
        case .detectedWhereStopped:  return "Detected where-stopped"
        case .rawGitHubActivity:     return "Raw GitHub activity"
        }
    }

    var explainer: String {
        switch self {
        case .gitCommits:            return "Commits authored on watched folders."
        case .linearIssues:          return "Issues you touched (status, comments, labels, cycles)."
        case .slackMentions:         return "Threads and messages where you're explicitly mentioned."
        case .githubPRs:             return "PRs you opened, merged, or reviewed."
        case .detectedDecisions:     return "Decisions extracted from messages and notes."
        case .detectedBlockers:      return "Patterns flagged as blockers (stuck Linear tickets, “blocked on” messages)."
        case .detectedOpenQuestions: return "Unresolved questions detected in your activity."
        case .detectedWhereStopped:  return "Snapshots of where work paused."
        case .rawGitHubActivity:     return "Stars, releases, branches, discussions."
        }
    }

    var sfSymbol: String {
        switch self {
        case .gitCommits:            return "arrow.triangle.branch"
        case .linearIssues:          return "list.bullet.rectangle"
        case .slackMentions:         return "at"
        case .githubPRs:             return "arrow.triangle.pull"
        case .detectedDecisions:     return "lightbulb"
        case .detectedBlockers:      return "hand.raised.fill"
        case .detectedOpenQuestions: return "questionmark.circle"
        case .detectedWhereStopped:  return "pause.rectangle"
        case .rawGitHubActivity:     return "cursorarrow.click"
        }
    }
}
