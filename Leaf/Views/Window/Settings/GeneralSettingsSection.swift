import SwiftUI
import ServiceManagement

struct GeneralSettingsSection: View {
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
    }

    private var statusColor: Color {
        switch launchAgent.status {
        case .enabled: .green
        case .requiresApproval: .orange
        case .notRegistered, .notFound: .gray
        @unknown default: .gray
        }
    }

    private var versionDisplay: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        return "\(short) (build \(build))"
    }
}
