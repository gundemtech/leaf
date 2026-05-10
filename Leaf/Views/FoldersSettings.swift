//
//  FoldersSettings.swift
//  Phase 2.4b — Settings tab "Folders" с per-folder L4/L5 toggle, enable/disable,
//  remove, и "Add folder…" через NSOpenPanel.
//
//  Track 2 / D4 — migrated to LeafSection (cta-slot Add) + LeafCard wrapping
//  ad-hoc folder rows. LeafEmptyState empty; LeafBanner.danger error.
//

import SwiftUI
import AppKit
import LeafCore

struct FoldersSettings: View {
    @Bindable var service: WatchedFoldersService

    var body: some View {
        LeafSection(
            title: "Watched folders",
            description: "Leaf отслеживает file-level activity (создание, изменение, удаление) только в выбранных папках. L4 (default) — popover показывает только имя папки. L5 — basename файла. Toggle применяется только к новым событиям. История удалённой папки остаётся локально."
        ) {
            VStack(alignment: .leading, spacing: LeafSpace.md) {
                if service.folders.isEmpty {
                    LeafEmptyState(
                        icon: LeafIcons.object.folderEmpty,
                        title: "No watched folders",
                        description: "Add a folder to track file activity in your projects."
                    )
                } else {
                    LeafCard(variant: .raised, padding: .tight) {
                        VStack(spacing: 0) {
                            let folders = service.folders
                            ForEach(Array(folders.enumerated()), id: \.element.id) { idx, folder in
                                folderRow(folder)
                                if idx < folders.count - 1 {
                                    LeafDivider()
                                }
                            }
                        }
                    }
                }

                if let error = service.lastErrorMessage {
                    LeafBanner(tone: .danger, title: "Couldn't add folder", description: error)
                }
            }
        } cta: {
            LeafButton(
                "Add…",
                variant: .secondary,
                size: .sm,
                icon: .asset(LeafIcons.action.add),
                action: addFoldersViaPanel
            )
        }
        .onAppear { service.reload() }
    }

    private func folderRow(_ folder: WatchedFolder) -> some View {
        HStack(alignment: .center, spacing: LeafSpace.md) {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: LeafSpace.md) {
                    Picker("Granularity", selection: Binding(
                        get: { folder.maxGranularity },
                        set: { service.update(id: folder.id, granularity: $0) }
                    )) {
                        Text("L4 — folder only").tag(WatchedFolderGranularity.L4)
                        Text("L5 — file names").tag(WatchedFolderGranularity.L5)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)

                    LeafToggle(
                        title: "Enabled",
                        isOn: Binding(
                            get: { folder.enabled },
                            set: { service.update(id: folder.id, enabled: $0) }
                        )
                    )
                }
            }
            Spacer()
            LeafIconButton(
                asset: LeafIcons.object.trash,
                variant: .ghost,
                size: .md,
                action: { service.remove(id: folder.id) }
            )
        }
        .padding(.horizontal, LeafSpace.md)
        .padding(.vertical, LeafSpace.md)
        .help(folder.path)
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
