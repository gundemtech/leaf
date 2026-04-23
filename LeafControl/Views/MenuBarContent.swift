//
//  MenuBarContent.swift
//  LeafControl
//

import SwiftUI
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

        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")

        Button("Quit LeafControl") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
