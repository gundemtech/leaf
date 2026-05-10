//
//  WindowSettingsView.swift
//  Track 2 / D4 — drop manual top-level header chrome. Pure VStack hosting
//  3 sub-section views, each rendering own LeafSection block.
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
                GeneralSettingsSection(launchAgent: launchAgent, updater: updater)
                FoldersSettings(service: watchedFolders)
                PrivacySettingsSection()
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
