//
//  WindowSettingsView.swift
//  Track 2 / D4 — drop manual top-level header chrome. Pure VStack hosting
//  sub-section views. Track 5 / S7 — F.11: WorkspaceSettingsSection added first
//  (team identity → collection setup → privacy → updates).
//

import SwiftUI
import LeafCore

struct WindowSettingsView: View {
    @Environment(LaunchAgentService.self) private var launchAgent
    @Environment(WatchedFoldersService.self) private var watchedFolders
    @Environment(UpdaterController.self) private var updater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LeafSpace.xxl) {
                WorkspaceSettingsSection()
                BackgroundCollectionSection(launchAgent: launchAgent)
                FoldersSettings(service: watchedFolders)
                LocalAppsSettingsSection()
                SystemObserversSettingsSection()
                ShareControlsSettingsSection()
                UpdatesSection(updater: updater)
                PrivacySettingsSection()
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
