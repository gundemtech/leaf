//
//  LeafControlApp.swift
//  LeafControl
//

import SwiftUI

@main
struct LeafControlApp: App {
    @State private var launchAgent = LaunchAgentService()

    var body: some Scene {
        MenuBarExtra("LeafControl", systemImage: "leaf") {
            MenuBarContent()
                .environment(launchAgent)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(launchAgent)
        }
    }
}
