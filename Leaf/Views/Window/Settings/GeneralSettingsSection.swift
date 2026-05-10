//
//  GeneralSettingsSection.swift
//  Track 2 / D4 — migrated from native Form to LeafSection chain. Background
//  collection card collapses to a single toggle row in the happy path; only
//  surfaces a LeafBanner with a refresh CTA when the LaunchAgent state is
//  actionable (requiresApproval, lastErrorMessage). Updates is a single
//  horizontal row.
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

                        if let error = launchAgent.lastErrorMessage {
                            LeafBanner(
                                tone: .danger,
                                title: "Background agent error",
                                description: error,
                                ctaTitle: "Try again",
                                onCTA: launchAgent.refreshStatus
                            )
                        } else if launchAgent.status == .requiresApproval {
                            LeafBanner(
                                tone: .warning,
                                title: "Login Items approval needed",
                                description: "Open System Settings → General → Login Items and enable Leaf to start collection.",
                                ctaTitle: "Refresh",
                                onCTA: launchAgent.refreshStatus
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

    private var versionShort: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String) ?? "?"
    }

    private var versionBuild: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleVersion"] as? String) ?? "?"
    }
}
