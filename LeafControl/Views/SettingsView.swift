//
//  SettingsView.swift
//  LeafControl
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(LaunchAgentService.self) private var launchAgent

    var body: some View {
        TabView {
            GeneralSettings(launchAgent: launchAgent)
                .tabItem { Label("General", systemImage: "gearshape") }

            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettings: View {
    @Bindable var launchAgent: LaunchAgentService

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
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section {
                Text("Phase 1 uses a hardcoded minimal blocklist (LeafControl's own processes + system UI).")
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
