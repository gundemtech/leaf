//
//  LocalAppsSettingsSection.swift
//  Phase Track-4 S2 — Settings → Local Apps. Per-adapter row with master
//  enabled toggle + permission-state badge + optional sub-field opt-in
//  (Mail mailbox name / Zoom meeting topic). Reads PermissionsService for
//  the shared LocalAppsStore + AppleScriptPermissionStore.
//

import SwiftUI
import AppKit
import LeafCore

struct LocalAppsSettingsSection: View {
    @Environment(PermissionsService.self) private var permissions

    var body: some View {
        LeafSection(
            title: "Local Apps",
            description: "Read what you're working on through Apple's automation API. Each app asks permission separately."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                ForEach(Self.adapters, id: \.bundleID) { app in
                    rowFor(app)
                }
            }
        }
    }

    /// Attach a `SettingsSubsection` anchor ID to the rows we deep-link into
    /// (Track-7 P2 chained sub-scroll). All other rows render without an ID.
    @ViewBuilder
    private func rowFor(_ app: LocalAppDescriptor) -> some View {
        let row = LocalAppRow(app: app, permissions: permissions)
        switch app.bundleID {
        case "com.apple.dt.Xcode":
            row.id(SettingsSubsection.xcode)
        case "us.zoom.xos":
            row.id(SettingsSubsection.zoom)
        default:
            row
        }
    }

    static let adapters: [LocalAppDescriptor] = [
        .init(
            bundleID: "com.apple.dt.Xcode",
            displayName: "Xcode",
            explainer: "Captures active document + project + scheme + build state.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "com.jetbrains.intellij",
            displayName: "JetBrains IDEs",
            explainer: "Captures active project + file across IntelliJ, PyCharm, GoLand, etc.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "com.apple.Music",
            displayName: "Music",
            explainer: "Captures current track + artist + play state.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "com.spotify.client",
            displayName: "Spotify",
            explainer: "Captures current track + artist + play state.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "com.apple.Notes",
            displayName: "Apple Notes",
            explainer: "Captures active note title only — never note body or content.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "com.apple.reminders",
            displayName: "Reminders",
            explainer: "Captures completed-reminder count + list name — never reminder titles or notes.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "com.apple.iCal",
            displayName: "Calendar",
            explainer: "Captures current view mode (Day / Week / Month) — never event titles or attendees.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "com.apple.mail",
            displayName: "Mail",
            explainer: "Captures active mailbox name — never message body, subject, sender, or recipients.",
            subFieldLabel: "Also capture mailbox names",
            subFieldKey: "mailboxName"
        ),
        .init(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            explainer: "Captures meeting state, session start/end timestamps, duration, and links to your calendar event (anonymized hash). Never attendee list, password, screen-share content, chat messages, or recording state.",
            subFieldLabel: "Also capture meeting topic",
            subFieldKey: "ownMeetingTopic"
        ),
        .init(
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            explainer: "Captures open tab titles + URLs — never page content, cookies, or history.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "com.google.Chrome",
            displayName: "Chrome",
            explainer: "Same as Safari.",
            subFieldLabel: nil,
            subFieldKey: nil
        ),
        .init(
            bundleID: "company.thebrowser.Browser",
            displayName: "Arc",
            explainer: "Same as Safari.",
            subFieldLabel: nil,
            subFieldKey: nil
        )
    ]
}

struct LocalAppDescriptor: Sendable {
    let bundleID: String
    let displayName: String
    let explainer: String
    let subFieldLabel: String?
    let subFieldKey: String?
}

private struct LocalAppRow: View {
    let app: LocalAppDescriptor
    let permissions: PermissionsService
    @State private var enabled: Bool = false
    @State private var subFieldOn: Bool = false
    @State private var permissionState: AppleScriptPermissionState = .notRequested

    var body: some View {
        LeafCard(variant: .raised, padding: .regular, header: { EmptyView() }) {
            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                HStack(alignment: .center, spacing: LeafSpace.md) {
                    AppIconView(bundleID: app.bundleID)
                    VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                        Text(app.displayName).font(LeafType.body.regular).foregroundStyle(LeafColor.text.primary)
                        Text(app.explainer).font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)
                    }
                    Spacer(minLength: 0)
                    permissionBadge
                    Toggle("", isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            enabled = newValue
                            permissions.setLocalAppEnabled(app.bundleID, newValue)
                        }
                    )).labelsHidden().toggleStyle(.switch).tint(LeafColor.accent.primary)
                }
                if let label = app.subFieldLabel, let key = app.subFieldKey, enabled {
                    Toggle(label, isOn: Binding(
                        get: { subFieldOn },
                        set: { newValue in
                            subFieldOn = newValue
                            permissions.setLocalAppSubFieldOptedIn(app.bundleID, field: key, optedIn: newValue)
                        }
                    ))
                    .font(LeafType.body.small)
                    .toggleStyle(.switch)
                    .tint(LeafColor.accent.primary)
                }
                if case .denied = permissionState {
                    LeafBanner(
                        tone: .warning,
                        title: "Permission denied",
                        description: "Open System Settings → Privacy → Automation to re-grant.",
                        ctaTitle: "Open Settings",
                        onCTA: { permissions.openAutomationSettings() }
                    )
                }
            }
        } footer: {
            EmptyView()
        }
        .onAppear {
            enabled = permissions.localAppsStore.isEnabled(app.bundleID)
            if let key = app.subFieldKey {
                subFieldOn = permissions.localAppsStore.isSubFieldOptedIn(app.bundleID, field: key)
            }
            permissionState = permissions.localAppsPermissionStore.cachedState(for: app.bundleID)
        }
    }

    @ViewBuilder
    private var permissionBadge: some View {
        switch permissionState {
        case .notRequested:
            Text("Waiting").font(LeafType.body.small).foregroundStyle(LeafColor.text.tertiary)
        case .granted:
            Text("Granted").font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)
        case .denied:
            Text("Denied").font(LeafType.body.small).foregroundStyle(LeafColor.text.secondary)
        case .appNotInstalled:
            Text("Not installed").font(LeafType.body.small).foregroundStyle(LeafColor.text.quaternary).italic()
        case .unavailable:
            Text("Unavailable").font(LeafType.body.small).foregroundStyle(LeafColor.text.quaternary)
        }
    }
}

private struct AppIconView: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                .fill(LeafColor.surface.inset)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "app.dashed")
                        .foregroundStyle(LeafColor.text.tertiary)
                )
        }
    }
}
