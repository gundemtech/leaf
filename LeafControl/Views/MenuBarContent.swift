//
//  MenuBarContent.swift
//  LeafControl
//

import SwiftUI
import LeafControlCore

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("LeafControl — Phase 0")
            .font(.headline)
        Text("Scaffolding only. Real UI lands in Phase 1.")
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
