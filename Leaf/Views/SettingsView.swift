//
//  SettingsView.swift
//  Leaf
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(LaunchAgentService.self) private var launchAgent
    @Environment(WatchedFoldersService.self) private var watchedFolders
    @Environment(LinearOAuthService.self) private var linearOAuth
    @Environment(GitHubOAuthService.self) private var githubOAuth
    @Environment(UpdaterController.self) private var updater

    var body: some View {
        TabView {
            GeneralSettings(launchAgent: launchAgent, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }

            FoldersSettings(service: watchedFolders)
                .tabItem { Label("Folders", systemImage: "folder.badge.gear") }

            ConnectionsSettings(service: linearOAuth, githubService: githubOAuth)
                .tabItem { Label("Connections", systemImage: "link") }

            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 540, height: 420)
    }
}

private struct GeneralSettings: View {
    @Bindable var launchAgent: LaunchAgentService
    let updater: UpdaterController

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Enable background collection",
                    isOn: Binding(
                        get: { launchAgent.isEnabled },
                        set: { newValue in
                            if newValue {
                                launchAgent.register()
                            } else {
                                launchAgent.unregister()
                            }
                        }
                    )
                )

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(launchAgent.statusDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = launchAgent.lastErrorMessage {
                    LabeledContent("Last error") {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Button("Refresh status") {
                    launchAgent.refreshStatus()
                }
            } header: {
                Text("Background collection")
            } footer: {
                Text("Agent runs as a LaunchAgent managed by macOS. Disable anytime in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Phase 3.1c — Sparkle update controls. Manual-only до Phase 3.5
            // R2 unblock (SUEnableAutomaticChecks=NO). После flip — также
            // periodic background checks (см. Info.plist SUScheduledCheckInterval).
            Section {
                LabeledContent("Version") {
                    Text(versionDisplay)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates served from updates.gundem.tech. Sparkle 2 + EdDSA-signed appcast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var statusColor: Color {
        switch launchAgent.status {
        case .enabled: .green
        case .requiresApproval: .orange
        case .notRegistered, .notFound: .gray
        @unknown default: .gray
        }
    }

    /// "1.0.0-alpha.1 (build 2)" — matches Phase 3.1a Info.plist version bump
    /// (CFBundleShortVersionString = MARKETING_VERSION, CFBundleVersion = CURRENT_PROJECT_VERSION).
    private var versionDisplay: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        return "\(short) (build \(build))"
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section {
                Text("Phase 1 uses a hardcoded minimal blocklist (Leaf's own processes + system UI).")
                    .foregroundStyle(.secondary)
                Text("Editable per-app Share Controls land in Phase 2.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
