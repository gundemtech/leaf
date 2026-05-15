//
//  WindowSettingsView.swift
//  Track 2 / D4 — drop manual top-level header chrome. Pure VStack hosting
//  4 sub-section views в порядке Background → Folders → Updates → Privacy
//  (cognitive flow: enable agent → tell it where to look → meta).
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
