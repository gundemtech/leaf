//
//  SystemObserversSettingsSection.swift
//  Phase Track-4 S3 — Settings → System Observers. 10 master-toggle rows
//  (intensity / clipboard / wifi / vpn / audio_route / mic_in_use / display
//  / screenshot_watcher / downloads_watcher / trash_watcher). Intensity row
//  has Input Monitoring TCC badge + "Open Settings" CTA. Reads
//  PermissionsService for SystemObserversStore + InputMonitoringPermissionStore.
//
//  Phase Track-6 P3 — +3 browser bookmark rows at the bottom:
//  Chrome bookmarks (opt-in sub-field on LocalAppsStore) / Safari bookmarks
//  (same, gated on FDA) / FDA warning CTA when Safari toggle is ON + FDA denied.
//
//  Track-6 P6 — IDEs sub-section appended: VSCode + JetBrains workspace/project
//  storage FSEvents watchers (both OFF by default, ADR-020 opt-in posture).
//

import LeafCore
import SwiftUI

struct SystemObserversSettingsSection: View {
    @Environment(PermissionsService.self) private var permissions

    var body: some View {
        LeafSection(
            title: "System Observers",
            description:
                "Background observers capture context shifts — audio routing, displays, voice calls, downloads. Local-only by default; Share Controls (above) gate what reaches your team."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                ForEach(Self.observers, id: \.key) { observer in
                    SystemObserverRow(observer: observer, permissions: permissions)
                }
                // Track-7 P2 — anchor for Settings deep-link from disabled
                // Browsers SurfaceRow. Groups both bookmark rows so the scroll
                // lands on the first of the pair.
                Group {
                    BrowserBookmarkRow(
                        displayName: "Browser bookmarks — Chrome",
                        sfSymbol: "bookmark",
                        explainer: "Tracks count of bookmarks (no titles, no URLs).",
                        isEnabled: permissions.localAppsStore.browserBookmarksChromeEnabled,
                        requiresFDA: false,
                        fdaGranted: permissions.fdaGranted,
                        onToggle: { permissions.localAppsStore.setBrowserBookmarksChromeEnabled($0) },
                        onOpenFDA: {}
                    )
                    BrowserBookmarkRow(
                        displayName: "Browser bookmarks — Safari",
                        sfSymbol: "safari",
                        explainer: "Requires Full Disk Access in System Settings.",
                        isEnabled: permissions.localAppsStore.browserBookmarksSafariEnabled,
                        requiresFDA: true,
                        fdaGranted: permissions.fdaGranted,
                        onToggle: { permissions.localAppsStore.setBrowserBookmarksSafariEnabled($0) },
                        onOpenFDA: { permissions.openFDAPane() }
                    )
                }
                .id(SettingsSubsection.browsers)
            }

            IDEStorageSettingsSection(store: permissions.localAppsStore)
                .id(SettingsSubsection.ides)
        }
    }

    static let observers: [SystemObserverDescriptor] = [
        .init(
            key: "intensity",
            displayName: "Intensity",
            sfSymbol: "speedometer",
            explainer: "Per-minute keyboard + mouse + app-switch counters. Counter only — never key contents.",
            requiresInputMonitoring: true
        ),
        .init(
            key: "clipboard",
            displayName: "Clipboard",
            sfSymbol: "doc.on.clipboard",
            explainer: "Count of clipboard changes. Never reads clipboard contents.",
            requiresInputMonitoring: false
        ),
        .init(
            key: "wifi",
            displayName: "WiFi",
            sfSymbol: "wifi",
            explainer: "Connected / disconnected state only. Never captures SSID or BSSID.",
            requiresInputMonitoring: false
        ),
        .init(
            key: "vpn",
            displayName: "VPN",
            sfSymbol: "network",
            explainer: "Connected / disconnected state only for system VPN profiles.",
            requiresInputMonitoring: false
        ),
        .init(
            key: "audio_route",
            displayName: "Audio Route",
            sfSymbol: "speaker.wave.2",
            explainer: "Builtin / headphones / bluetooth / airplay / usb / HDMI category — no device names.",
            requiresInputMonitoring: false
        ),
        .init(
            key: "mic_in_use",
            displayName: "Mic In Use",
            sfSymbol: "mic",
            explainer: "Detects when any app records from system mic (voice call signal). Never reads audio.",
            requiresInputMonitoring: false
        ),
        .init(
            key: "display",
            displayName: "Displays",
            sfSymbol: "display",
            explainer: "Display connect / disconnect events. Never captures screen pixels.",
            requiresInputMonitoring: false
        ),
        .init(
            key: "screenshot_watcher",
            displayName: "Screenshot Watcher",
            sfSymbol: "camera.viewfinder",
            explainer: "Detects new screenshots in your screenshot directory. Filename only.",
            requiresInputMonitoring: false
        ),
        .init(
            key: "downloads_watcher",
            displayName: "Downloads Watcher",
            sfSymbol: "arrow.down.circle",
            explainer: "Detects new files in ~/Downloads. Filename only; never opens file contents.",
            requiresInputMonitoring: false
        ),
        .init(
            key: "trash_watcher",
            displayName: "Trash Watcher",
            sfSymbol: "trash",
            explainer: "Detects items added / emptied from Trash. Never reads file contents.",
            requiresInputMonitoring: false
        ),
    ]
}

struct SystemObserverDescriptor: Sendable {
    let key: String
    let displayName: String
    let sfSymbol: String
    let explainer: String
    let requiresInputMonitoring: Bool
}

// MARK: - Phase Track-6 P3 — Browser bookmark rows

/// A Settings row for Chrome or Safari bookmark-count observer opt-in.
/// `requiresFDA` true → shows a warning LeafBanner when the toggle is ON
/// but Full Disk Access is not granted, with an "Open System Settings" CTA.
private struct BrowserBookmarkRow: View {
    let displayName: String
    let sfSymbol: String
    let explainer: String
    let isEnabled: Bool
    let requiresFDA: Bool
    let fdaGranted: Bool
    let onToggle: (Bool) -> Void
    let onOpenFDA: () -> Void

    @State private var enabled: Bool = false

    var body: some View {
        LeafCard(variant: .raised, padding: .regular, header: { EmptyView() }) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(alignment: .center, spacing: LeafSpace.md) {
                    Image(systemName: sfSymbol)
                        .font(.system(size: 18))
                        .foregroundStyle(LeafColor.text.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text(displayName)
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                        Text(explainer)
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { enabled },
                            set: { newValue in
                                enabled = newValue
                                onToggle(newValue)
                            }
                        )
                    ).labelsHidden().toggleStyle(.switch).tint(LeafColor.accent.primary)
                }
                if requiresFDA && enabled && !fdaGranted {
                    LeafBanner(
                        tone: .warning,
                        title: "Full Disk Access required",
                        description:
                            "Safari bookmarks live in ~/Library/Safari — readable only with Full Disk Access. After granting, restart Leaf.",
                        ctaTitle: "Open System Settings",
                        onCTA: onOpenFDA
                    )
                }
            }
        } footer: {
            EmptyView()
        }
        .onAppear { enabled = isEnabled }
    }
}

// MARK: - Track-6 P6 IDEs sub-section

/// Four-row sub-section for VSCode-family + JetBrains IDE storage watchers
/// and Track-9 T1 depth toggles (AX line capture + workspace path tracking).
/// Reads/writes `LocalAppsStore` UserDefaults keys; storage rows default OFF
/// (ADR-020), Track-9 rows default ON (opt-out posture per spec §3.6).
private struct IDEStorageSettingsSection: View {
    @ObservedObject var store: LocalAppsStore

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text("IDEs")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .padding(.top, LeafSpace.sm)

            IDEStorageToggleRow(
                sfSymbol: "chevron.left.forwardslash.chevron.right",
                displayName: "VSCode workspace tracking",
                explainer:
                    "Detects workspace opens across VSCode, Cursor, Insiders, and VSCodium. Workspace name only — never file contents.",
                isOn: Binding(
                    get: { store.vscodeStorageEnabled },
                    set: { store.vscodeStorageEnabled = $0 }
                )
            )

            IDEStorageToggleRow(
                sfSymbol: "cube",
                displayName: "JetBrains recent projects",
                explainer:
                    "Detects recent project activations across IntelliJ, PyCharm, GoLand, etc. Project display name only — never file contents.",
                isOn: Binding(
                    get: { store.jetbrainsStorageEnabled },
                    set: { store.jetbrainsStorageEnabled = $0 }
                )
            )

            // Track-9 T1 — depth toggles for YOU·NOW enrichment
            IDEStorageToggleRow(
                sfSymbol: "text.cursor",
                displayName: "Xcode line capture",
                explainer:
                    "Capture cursor line in active document via Accessibility. Used by Home YOU·NOW to show cursor position.",
                isOn: Binding(
                    get: { store.axLineCaptureEnabled },
                    set: { store.axLineCaptureEnabled = $0 }
                )
            )

            IDEStorageToggleRow(
                sfSymbol: "folder.badge.gearshape",
                displayName: "IDE workspace path tracking",
                explainer:
                    "Record workspace path (~/path/to/project) for VSCode-family and JetBrains. Used by Home YOU·NOW to derive branch and Linear ID.",
                isOn: Binding(
                    get: { store.ideWorkspacePathTrackingEnabled },
                    set: { store.ideWorkspacePathTrackingEnabled = $0 }
                )
            )
        }
    }
}

private struct IDEStorageToggleRow: View {
    let sfSymbol: String
    let displayName: String
    let explainer: String
    @Binding var isOn: Bool

    var body: some View {
        LeafCard(variant: .raised, padding: .regular, header: { EmptyView() }) {
            HStack(alignment: .center, spacing: LeafSpace.md) {
                Image(systemName: sfSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(LeafColor.text.secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                    Text(displayName)
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.primary)
                    Text(explainer)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(LeafColor.accent.primary)
            }
        } footer: {
            EmptyView()
        }
    }
}

// MARK: - System observer rows

private struct SystemObserverRow: View {
    let observer: SystemObserverDescriptor
    let permissions: PermissionsService
    @State private var enabled: Bool = false

    var body: some View {
        LeafCard(variant: .raised, padding: .regular, header: { EmptyView() }) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(alignment: .center, spacing: LeafSpace.md) {
                    Image(systemName: observer.sfSymbol)
                        .font(.system(size: 18))
                        .foregroundStyle(LeafColor.text.secondary)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text(observer.displayName)
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                        Text(observer.explainer)
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.secondary)
                    }
                    Spacer(minLength: 0)
                    if observer.requiresInputMonitoring {
                        permissionBadge
                    }
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { enabled },
                            set: { newValue in
                                enabled = newValue
                                permissions.setSystemObserverEnabled(observer.key, newValue)
                            }
                        )
                    ).labelsHidden().toggleStyle(.switch).tint(LeafColor.accent.primary)
                }
                if observer.requiresInputMonitoring && enabled && !permissions.inputMonitoringGranted {
                    LeafBanner(
                        tone: .warning,
                        title: "Input Monitoring required",
                        description:
                            "Intensity uses macOS Input Monitoring to count keystrokes (it never reads key content). Grant access to enable.",
                        ctaTitle: "Open Settings",
                        onCTA: { permissions.openInputMonitoringSettings() }
                    )
                }
            }
        } footer: {
            EmptyView()
        }
        .onAppear {
            enabled = permissions.systemObserversStore.isEnabled(observer.key)
        }
    }

    @ViewBuilder
    private var permissionBadge: some View {
        if permissions.inputMonitoringGranted {
            Text("Granted").font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)
        } else {
            Text("Waiting").font(LeafType.body.small).foregroundStyle(LeafColor.text.tertiary)
        }
    }
}
