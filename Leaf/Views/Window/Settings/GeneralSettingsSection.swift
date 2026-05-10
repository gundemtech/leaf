//
//  GeneralSettingsSection.swift
//  Track 2 / D4 — migrated from native Form to LeafSection chain. LaunchAgent
//  toggle + status row + last-error inline + refresh CTA; Updates section with
//  version row + Check-for-Updates CTA.
//

import SwiftUI
import ServiceManagement
import LeafCore

struct GeneralSettingsSection: View {
    @Bindable var launchAgent: LaunchAgentService
    let updater: UpdaterController

    var body: some View {
        VStack(spacing: LeafSpace.xl) {
            LeafSection(
                title: "Background collection",
                description: "Agent runs as a LaunchAgent managed by macOS. Disable anytime in System Settings → General → Login Items."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    VStack(alignment: .leading, spacing: LeafSpace.md) {
                        LeafToggle(
                            title: "Enable background collection",
                            isOn: Binding(
                                get: { launchAgent.isEnabled },
                                set: { newValue in
                                    if newValue { launchAgent.register() }
                                    else        { launchAgent.unregister() }
                                }
                            )
                        )

                        LeafDivider()

                        statusRow

                        if let error = launchAgent.lastErrorMessage {
                            LeafDivider()
                            LeafBanner(tone: .danger, title: "Last error", description: error)
                        }

                        HStack {
                            Spacer()
                            LeafButton(
                                "Refresh status",
                                variant: .secondary,
                                size: .sm,
                                action: launchAgent.refreshStatus
                            )
                        }
                    }
                }
            }

            LeafSection(
                title: "Updates",
                description: "Updates served from updates.gundem.tech. Sparkle 2 + EdDSA-signed appcast."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    VStack(alignment: .leading, spacing: LeafSpace.md) {
                        versionRow
                        HStack {
                            Spacer()
                            LeafButton(
                                "Check for Updates…",
                                variant: .secondary,
                                size: .sm,
                                action: updater.checkForUpdates
                            )
                        }
                    }
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: LeafSpace.sm) {
            LeafDot(tone: statusTone, size: .md)
            Text("Status")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Spacer()
            Text(launchAgent.statusDescription)
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private var versionRow: some View {
        HStack(spacing: LeafSpace.sm) {
            Text("Version")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
            Spacer()
            Text(versionDisplay)
                .font(LeafType.mono.regular)
                .foregroundStyle(LeafColor.text.tertiary)
        }
    }

    private var statusTone: LeafDotTone {
        switch launchAgent.status {
        case .enabled:          return .success
        case .requiresApproval: return .warning
        case .notRegistered, .notFound: return .muted
        @unknown default:       return .muted
        }
    }

    private var versionDisplay: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        return "\(short) (build \(build))"
    }
}
