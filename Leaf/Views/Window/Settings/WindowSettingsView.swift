//
//  WindowSettingsView.swift
//  Track 2 / D4 — drop manual top-level header chrome. Pure VStack hosting
//  sub-section views. Track 5 / S7 F.11 — WorkspaceSettingsSection added.
//  Track 5 / S8 T9 — full reorder + Account + Notifications sections (spec §9).
//
//  Order (top→bottom):
//    1. Account              (T9 — identity + pubkey copy + Tier chip)
//    2. Workspace            (S7 — team identity + members + invites)
//    3. Share Controls       (S5 — per-source auto-share toggles)
//    4. Notifications        (T9 — 4 sub-groups × 11 prefs)
//    5. Privacy              (T10 expands; T9 preserves the existing stub)
//    6. Background collection
//    7. Folders
//    8. Local apps
//    9. System observers
//   10. Updates
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
                // AccountSettingsSection moved to ProfileView (sidebar Profile tab)
                // to separate identity / tier from operational settings.
                WorkspaceSettingsSection()
                ShareControlsSettingsSection()
                NotificationsSettingsSection()
                PrivacySettingsSection()
                BackgroundCollectionSection(launchAgent: launchAgent)
                FoldersSettings(service: watchedFolders)
                LocalAppsSettingsSection()
                SystemObserversSettingsSection()
                AIToolsSettingsSection()
                UpdatesSection(updater: updater)
            }
            .padding(LeafSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
