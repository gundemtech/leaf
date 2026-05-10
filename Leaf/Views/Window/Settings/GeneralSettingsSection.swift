//
//  GeneralSettingsSection.swift
//  Track 2 / D4 — migrated from native Form to LeafSection chain. LaunchAgent
//  toggle + inline status row + last-error banner; Updates section is a single
//  horizontal row "version · build" + Check-for-Updates CTA.
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

                        HStack(spacing: LeafSpace.sm) {
                            LeafDot(tone: statusTone, size: .md)
                            Text(launchAgent.statusDescription)
                                .font(LeafType.body.small)
                                .foregroundStyle(LeafColor.text.secondary)
                            Spacer()
                            LeafButton(
                                "Refresh",
                                variant: .ghost,
                                size: .sm,
                                action: launchAgent.refreshStatus
                            )
                        }

                        if let error = launchAgent.lastErrorMessage {
                            LeafBanner(tone: .danger, title: "Last error", description: error)
                        }
                    }
                }
            }

            LeafSection(
                title: "Updates",
                description: "Updates served from updates.gundem.tech. Sparkle 2 + EdDSA-signed appcast."
            ) {
                LeafCard(variant: .raised, padding: .regular) {
                    HStack(alignment: .center, spacing: LeafSpace.md) {
                        VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                            Text("Leaf \(versionShort)")
                                .font(LeafType.body.regular)
                                .foregroundStyle(LeafColor.text.primary)
                            Text("Build \(versionBuild)")
                                .font(LeafType.body.small)
                                .foregroundStyle(LeafColor.text.tertiary)
                        }
                        Spacer()
                        LeafButton(
                            "Check for updates",
                            variant: .secondary,
                            size: .sm,
                            action: updater.checkForUpdates
                        )
                    }
                }
            }
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

    private var versionShort: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String) ?? "?"
    }

    private var versionBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleVersion"] as? String) ?? "?"
    }
}
