//
//  MenuBarContent.swift
//  Leaf
//
//  Minimal popover: FOCUS TODAY hero + top-3 apps + Open/Quit.
//  Track 2 / D4 — migrated to LeafMenuBarLayout (360pt) + LeafBanner inline
//  (replaces old banner wrapper). LeafButton.primary "Open"; native borderless
//  Quit preserved (macOS conventional pattern).
//

import SwiftUI
import AppKit
import LeafCore

struct MenuBarContent: View {
    @Environment(LaunchAgentService.self) private var launchAgent
    @Environment(PermissionsService.self) private var permissions
    @Environment(InsightsReader.self) private var reader
    @Environment(WindowState.self) private var windowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            normalBody
        } else {
            OnboardingView(onDone: {
                hasCompletedOnboarding = true
                UserDefaults.standard.removeObject(forKey: "onboardingStep")
            })
        }
    }

    private var normalBody: some View {
        LeafMenuBarLayout {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                if !launchAgent.isEnabled { agentOffBanner }
                permissionsBanner
                hero
                LeafDivider()
                content
                LeafDivider()
                controls
            }
        }
        .onAppear {
            launchAgent.refreshStatus()
            permissions.refresh()
            permissions.startPolling(every: 4.0)
            reader.refresh()
        }
        .onDisappear {
            permissions.stopPolling()
        }
    }

    // MARK: - Banners

    private var agentOffBanner: some View {
        LeafBanner(
            tone: .warning,
            title: "Background collection is off",
            ctaTitle: "Enable",
            onCTA: openMainWindowToSettings
        )
    }

    @ViewBuilder
    private var permissionsBanner: some View {
        if !permissions.axGranted {
            LeafBanner(
                tone: .warning,
                title: "Accessibility disabled",
                ctaTitle: "Grant",
                onCTA: permissions.openAXSettings
            )
        } else if !permissions.fdaGranted {
            LeafBanner(
                tone: .warning,
                title: "Full Disk Access disabled",
                description: "Watched Folders won't track ~/Documents",
                ctaTitle: "Grant",
                onCTA: permissions.openFDASettings
            )
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text("FOCUS TODAY").leafSectionLabel().foregroundStyle(LeafColor.text.tertiary)
            Text(focusTotalDisplay)
                .font(LeafType.title.large)
                .foregroundStyle(LeafColor.text.primary)
                .monospacedDigit()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .loading:
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
        case .notConfigured(let msg), .empty(let msg), .error(let msg):
            Text(msg)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded(let snapshot, _):
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                topAppsList(snapshot.topApps)
                let lines = providerSummaryLines(snapshot)
                if !lines.isEmpty {
                    LeafDivider()
                    VStack(alignment: .leading, spacing: LeafSpace.xs) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(LeafType.body.small)
                                .foregroundStyle(LeafColor.text.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }
        }
    }

    private func topAppsList(_ apps: [AppTimeEntry]) -> some View {
        let top = Array(apps.prefix(3))
        return Group {
            if top.isEmpty {
                Text("No activity yet today.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
            } else {
                LeafCard(variant: .rest, padding: .tight) {
                    VStack(spacing: 0) {
                        ForEach(Array(top.enumerated()), id: \.element.bundleID) { idx, entry in
                            HStack {
                                Text(AppNameResolver.shared.displayName(for: entry.bundleID))
                                    .font(LeafType.body.regular)
                                    .foregroundStyle(LeafColor.text.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(formatDuration(entry.duration))
                                    .font(LeafType.mono.small)
                                    .foregroundStyle(LeafColor.text.tertiary)
                            }
                            .padding(.horizontal, LeafSpace.sm)
                            .padding(.vertical, LeafSpace.xs)
                            if idx < top.count - 1 { LeafDivider() }
                        }
                    }
                }
            }
        }
    }

    private func providerSummaryLines(_ snapshot: InsightsSnapshot) -> [String] {
        var lines: [String] = []
        if snapshot.linearIssuesTouched > 0 {
            let closed = snapshot.linearTransitions?.completed ?? 0
            let suffix = closed > 0 ? " · \(closed) closed" : ""
            lines.append("Linear · \(snapshot.linearIssuesTouched) issue\(snapshot.linearIssuesTouched == 1 ? "" : "s")\(suffix)")
        }
        if snapshot.githubEventsCount > 0 {
            let repos = snapshot.githubByRepo.count
            let suffix = repos > 0 ? " · \(repos) repo\(repos == 1 ? "" : "s")" : ""
            lines.append("GitHub · \(snapshot.githubEventsCount) event\(snapshot.githubEventsCount == 1 ? "" : "s")\(suffix)")
        }
        if snapshot.slackMessagesCount > 0 || snapshot.slackHuddleMinutes > 0 {
            var parts: [String] = []
            if snapshot.slackMessagesCount > 0 {
                parts.append("\(snapshot.slackMessagesCount) msg\(snapshot.slackMessagesCount == 1 ? "" : "s")")
            }
            if snapshot.slackHuddleMinutes > 0 {
                parts.append("\(snapshot.slackHuddleMinutes)m huddle")
            }
            lines.append("Slack · " + parts.joined(separator: " · "))
        }
        return lines
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: LeafSpace.sm) {
            LeafButton(
                "Open",
                variant: .primary,
                size: .sm,
                icon: .asset(LeafIcons.action.external),
                action: openMainWindow
            )
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(LeafColor.text.secondary)
                .keyboardShortcut("q")
        }
    }

    // MARK: - Helpers

    private var focusTotalDisplay: String {
        if case .loaded(let snapshot, _) = reader.state {
            let total = snapshot.topApps.map(\.duration).reduce(0, +)
            return total == 0 ? "—" : formatDuration(total)
        }
        return "—"
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        dismiss()
    }

    private func openMainWindowToSettings() {
        windowState.section = .settings
        openMainWindow()
    }
}
