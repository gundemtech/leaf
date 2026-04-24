//
//  MenuBarContent.swift
//  LeafControl
//
//  Popover в menu bar: Today header, top-5 apps с durations, bar chart.
//  Требует .menuBarExtraStyle(.window) — Charts не рендерится в .menu стиле.
//

import SwiftUI
import AppKit
import Charts
import LeafControlCore

struct MenuBarContent: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(LaunchAgentService.self) private var launchAgent
    @State private var reader = InsightsReader()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !launchAgent.isEnabled {
                agentOffBanner
            }
            header
            Divider()
            content
            Divider()
            controls
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            launchAgent.refreshStatus()
            reader.refresh()
        }
    }

    // MARK: - Sections

    private var agentOffBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Background collection is off")
                .font(.caption)
            Spacer()
            Button("Enable") { openSettingsWindow() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today")
                .font(.headline)
            Spacer()
            if case .loaded(_, let ts) = reader.state {
                Text(ts, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch reader.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
        case .notConfigured(let msg), .empty(let msg), .error(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        case .loaded(let entries, _):
            loadedContent(entries: entries)
        }
    }

    private func loadedContent(entries: [AppTimeEntry]) -> some View {
        let top = Array(entries.prefix(5))
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(top, id: \.bundleID) { entry in
                    HStack {
                        Text(AppNameResolver.shared.displayName(for: entry.bundleID))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(formatDuration(entry.duration))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            Chart(top, id: \.bundleID) { entry in
                BarMark(
                    x: .value("App", AppNameResolver.shared.displayName(for: entry.bundleID)),
                    y: .value("Minutes", entry.duration / 60.0)
                )
            }
            .frame(height: 120)
            .chartYAxis { AxisMarks(position: .leading) }
        }
    }

    private var controls: some View {
        HStack {
            Button("Settings…") { openSettingsWindow() }
                .keyboardShortcut(",")
            Button("Refresh") { reader.refresh() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    // MARK: - Helpers

    /// LSUIElement apps не активируются автоматом при openSettings() —
    /// окно появляется "за" другими. Сначала активируем app, затем открываем.
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        for window in NSApp.windows where window.title.lowercased().contains("settings")
            || window.title.lowercased().contains("leafcontrol") {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
