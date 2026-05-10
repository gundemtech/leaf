//
//  MenuBarContent.swift
//  Leaf
//
//  Минимальный popover: FOCUS TODAY hero + top-3 apps + Open/Quit.
//  Все детали (per-provider, files, charts) — в главном окне.
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
        VStack(alignment: .leading, spacing: 14) {
            if !launchAgent.isEnabled {
                agentOffBanner
            }
            permissionsBanner
            hero
            Divider().opacity(0.4)
            content
            Divider().opacity(0.4)
            controls
        }
        .padding(16)
        .frame(width: 280)
        .background(Color.leafBackground)
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
        BannerView(
            color: .orange,
            title: "Background collection is off",
            action: "Enable",
            onTap: openMainWindowToSettings
        )
    }

    @ViewBuilder
    private var permissionsBanner: some View {
        if !permissions.axGranted {
            BannerView(
                color: .orange,
                title: "Accessibility disabled",
                action: "Grant",
                onTap: permissions.openAXSettings
            )
        } else if !permissions.fdaGranted {
            BannerView(
                color: .orange,
                title: "Full Disk Access disabled",
                subtitle: "Watched Folders won't track ~/Documents",
                action: "Grant",
                onTap: permissions.openFDASettings
            )
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FOCUS TODAY")
                    .leafLabelStyle()
                Text(focusTotalDisplay)
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(.leafInk)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        case .notConfigured(let msg), .empty(let msg), .error(let msg):
            Text(msg)
                .font(.leafCaption)
                .foregroundStyle(.leafMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        case .loaded(let snapshot, _):
            VStack(alignment: .leading, spacing: 12) {
                topAppsList(snapshot.topApps)
                let lines = providerSummaryLines(snapshot)
                if !lines.isEmpty {
                    Divider().opacity(0.3)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.leafCaption)
                                .foregroundStyle(.leafInk.opacity(0.8))
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
        return VStack(alignment: .leading, spacing: 8) {
            if top.isEmpty {
                Text("No activity yet today.")
                    .font(.leafCaption)
                    .foregroundStyle(.leafMuted)
            } else {
                ForEach(top, id: \.bundleID) { entry in
                    HStack {
                        Text(AppNameResolver.shared.displayName(for: entry.bundleID))
                            .font(.leafBody)
                            .foregroundStyle(.leafInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(formatDuration(entry.duration))
                            .font(.leafBody.monospacedDigit())
                            .foregroundStyle(.leafMuted)
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
        HStack(spacing: 8) {
            LeafProminentButton(action: openMainWindow) {
                Label("Open", image: LeafIcons.action.external)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.leafMuted)
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
