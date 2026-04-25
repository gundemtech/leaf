//
//  FoldersSettings.swift
//  Leaf
//
//  Phase 2.4b — Settings tab "Folders" с per-folder L4/L5 toggle, enable/disable,
//  remove, и "Add folder…" через NSOpenPanel.
//

import SwiftUI
import AppKit
import LeafCore

struct FoldersSettings: View {
    @Bindable var service: WatchedFoldersService

    var body: some View {
        Form {
            Section {
                if service.folders.isEmpty {
                    emptyState
                } else {
                    folderList
                }
            } header: {
                HStack {
                    Text("Watched folders")
                    Spacer()
                    Button {
                        addFoldersViaPanel()
                    } label: {
                        Label("Add…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Leaf отслеживает file-level activity (создание, изменение, удаление) только в выбранных папках.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("L4 (default) — popover показывает только имя папки. L5 — basename файла. Toggle применяется только к новым событиям.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("История удалённой папки остаётся локально. Right-to-deletion — отдельный flow.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let error = service.lastErrorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { service.reload() }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No watched folders")
                .font(.headline)
            Text("Add a folder to track file activity in your projects.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var folderList: some View {
        ForEach(service.folders, id: \.id) { folder in
            folderRow(folder)
        }
    }

    private func folderRow(_ folder: WatchedFolder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(role: .destructive) {
                    service.remove(id: folder.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .help(folder.path)

            HStack {
                Picker("Granularity", selection: Binding(
                    get: { folder.maxGranularity },
                    set: { service.update(id: folder.id, granularity: $0) }
                )) {
                    Text("L4 — folder only").tag(WatchedFolderGranularity.L4)
                    Text("L5 — file names").tag(WatchedFolderGranularity.L5)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Toggle("Enabled", isOn: Binding(
                    get: { folder.enabled },
                    set: { service.update(id: folder.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - NSOpenPanel

    private func addFoldersViaPanel() {
        // LSUIElement quirk — без activate panel может оказаться "за" другими.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select folders to monitor for file activity"
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            // Default granularity L4 — privacy-first per architecture.md.
            // L5 — explicit per-folder opt-in через Picker после add.
            service.add(path: url.path, granularity: .L4)
        }
    }
}
