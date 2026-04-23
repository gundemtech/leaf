//
//  MenuBarContent.swift
//  LeafControl
//

import SwiftUI
import AppKit
import LeafControlCore

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(LaunchAgentService.self) private var launchAgent

    var body: some View {
        Text("LeafControl — Phase 1.2")
            .font(.headline)
        Text("Agent: \(launchAgent.statusDescription)")
            .font(.caption)
            .foregroundStyle(.secondary)

        Divider()

        Text("Signal types: \(SignalType.allCases.count)")
            .font(.caption)
        Text("Granularity levels: \(Granularity.allCases.count)")
            .font(.caption)

        Divider()

        Button("Settings…") {
            openSettingsWindow()
        }
        .keyboardShortcut(",")

        Button("Quit LeafControl") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// LSUIElement apps не активируются автоматом при openSettings() —
    /// окно появляется "за" другими. Сначала активируем app, затем открываем.
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        // Belt and suspenders: принудительно выводим Settings-окно на передний план.
        for window in NSApp.windows where window.title.lowercased().contains("settings")
            || window.title.lowercased().contains("leafcontrol") {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
