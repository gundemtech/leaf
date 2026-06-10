//
//  WindowSettingsView.swift
//  Settings redesign — the former single ScrollView of 13 stacked sections is
//  split into 5 categories switched via a top LeafTab strip (mirrors the
//  Activity screen's header → LeafTab → content layout). Only the selected
//  category's sub-sections mount at a time, so each view is a short scroll
//  instead of one mile-long dump.
//
//  Categories (see SettingsCategory):
//    • Privacy        — PrivacySettingsSection (device-wide retention)
//    • Notifications  — NotificationsSettingsSection
//    • Data           — Background / Folders / LocalApps / SystemObservers /
//                       AITools / BrowserAllowList
//    • General        — Advanced / Updates / DebugDiagnostics
//
//  Workspace-scoped sections (identity / members / invites / share rules /
//  danger zone) moved to the Team workspace hub — Settings is device-level
//  only now.
//
//  The sub-section views are unchanged — they each wrap themselves in
//  LeafSection + LeafCard and pull their own @Environment. Gating them behind a
//  tab is safe: every section's `.onAppear`/`.task` is a display-refresh of its
//  own data (e.g. ShareControls/ActiveTokens/PendingRequests re-run their
//  `.task(id: activeWorkspaceID)` on mount), so switching workspace and then
//  opening a tab still pulls fresh data — no global init is lost.
//

import SwiftUI
import LeafCore

struct WindowSettingsView: View {
    @Environment(LaunchAgentService.self) private var launchAgent
    @Environment(WatchedFoldersService.self) private var watchedFolders
    @Environment(UpdaterController.self) private var updater

    @State private var browserAllowListStore = BrowserAllowListStore()

    /// Persisted selected category. `@AppStorage` binds RawRepresentable<String>
    /// directly, so the choice survives leaving/returning to Settings and app
    /// relaunch. Namespace mirrors `leaf.ui.showAnalyticsSection` (Sidebar).
    // Default .sharing ("Privacy") — also the fallback for stale persisted
    // "workspace" raw values after the hub migration (decode to nil →
    // declared default; no crash).
    @AppStorage("leaf.ui.settingsCategory") private var category: SettingsCategory = .sharing

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xxl) {
                header
                LeafTab(
                    selection: $category,
                    tabs: SettingsCategory.allCases,
                    label: { $0.title }
                )
                content(for: category)
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("SETTINGS · \(category.title.uppercased())")
                .leafSectionLabel()
                .foregroundStyle(LeafColor.text.tertiary)
            Text(description(for: category))
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.secondary)
        }
    }

    private func description(for category: SettingsCategory) -> String {
        switch category {
        case .sharing:
            "How long shared events are kept on this device. Per-workspace sharing lives on the Team page."
        case .notifications:
            "Which teammate pushes reach you, and how they're delivered."
        case .data:
            "What Leaf captures on this Mac. Off by default — you choose the sources."
        case .general:
            "App behavior and updates."
        }
    }

    // MARK: - Category content

    @ViewBuilder
    private func content(for category: SettingsCategory) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xxl) {
            switch category {
            case .sharing:
                PrivacySettingsSection()
                AIPrivacySection()
            case .notifications:
                NotificationsSettingsSection()
            case .data:
                BackgroundCollectionSection(launchAgent: launchAgent)
                FoldersSettings(service: watchedFolders)
                LocalAppsSettingsSection()
                SystemObserversSettingsSection()
                AIToolsSettingsSection()
                AIAnswersSettingsSection()
                BrowserAllowListSection(store: browserAllowListStore)
            case .general:
                AdvancedSettingsSection()
                UpdatesSection(updater: updater)
                // Always visible (incl. signed release): this is a user-facing
                // troubleshooting panel ("why isn't it detecting"), not a dev-only
                // tool — matches DebugDiagnosticsSection's own design intent.
                DebugDiagnosticsSection()
            }
        }
    }
}
