//
//  LeafControlApp.swift
//  LeafControl
//

import SwiftUI

@main
struct LeafControlApp: App {
    var body: some Scene {
        MenuBarExtra("LeafControl", systemImage: "leaf") {
            MenuBarContent()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}
