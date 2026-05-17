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
    @Environment(RouteCoordinator.self) private var coordinator
    // Track-7 — lifted to LeafApp so Home (SurfacesSection) reads the same
    // store for the Browsers surface enable-state. Single instance per app.
    @Environment(BrowserAllowListStore.self) private var browserAllowListStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: LeafSpace.xxl) {
                    BackgroundCollectionSection(launchAgent: launchAgent)
                        .id(SettingsSection.background)
                    FoldersSettings(service: watchedFolders)
                        .id(SettingsSection.folders)
                    LocalAppsSettingsSection()
                        .id(SettingsSection.localApps)
                    SystemObserversSettingsSection()
                        .id(SettingsSection.systemObservers)
                    AIToolsSettingsSection()
                        .id(SettingsSection.aiTools)
                    BrowserAllowListSection(store: browserAllowListStore)
                        .id(SettingsSection.browserAllowList)
                    UpdatesSection(updater: updater)
                        .id(SettingsSection.updates)
                    PrivacySettingsSection()
                        .id(SettingsSection.privacy)
                }
                .padding(LeafSpace.xxl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { applyPendingTarget(proxy: proxy) }
            .onChange(of: coordinator.pendingSettingsTarget?.section) { _, _ in
                applyPendingTarget(proxy: proxy)
            }
        }
    }

    private func applyPendingTarget(proxy: ScrollViewProxy) {
        guard let target = coordinator.consumePendingSettingsTarget() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(target.section, anchor: .top)
            }
            // Track-7 P2 — chained sub-anchor scroll. After the section header
            // settles (~0.25s), scroll a second time to the specific sub-row
            // (e.g. Local Apps → Xcode, System Observers → Browsers).
            if let sub = target.sub {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(sub, anchor: .top)
                    }
                }
            }
        }
    }
}
