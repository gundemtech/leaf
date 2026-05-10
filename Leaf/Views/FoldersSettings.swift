//
//  FoldersSettings.swift
//  Phase 2.4b — Settings tab "Folders" с per-folder L4/L5 toggle, enable/disable,
//  remove, и "Add folder…" через NSOpenPanel.
//
//  Track 2 / D4 — migrated to LeafSection (cta-slot Add) + LeafCard wrapping
//  ad-hoc folder rows. LeafEmptyState empty; LeafBanner.danger error.
//
//  Track 2 D4-followup — granularity picker switched from `.segmented` (native
//  blue chrome read foreign on Leaf canvas) to `.menu` popup; per-row toggle
//  uses empty title (just the switch); description rewritten en, tightened.
//

import SwiftUI
import AppKit
import LeafCore

struct FoldersSettings: View {
    @Bindable var service: WatchedFoldersService

    var body: some View {
        LeafSection(
            title: "Watched folders",
            description: "Leaf tracks file activity (creation, modification, deletion) only inside selected folders. L4 keeps the folder name; L5 also captures file basenames. Toggle applies to new events only."
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
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder.path)
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: LeafSpace.md)
            granularityMenu(folder)
            LeafToggle(
                title: "",
                isOn: Binding(
                    get: { folder.enabled },
                    set: { service.update(id: folder.id, enabled: $0) }
                )
            )
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

    /// Compact Leaf-tokenized Menu replacing native macOS Picker chrome
    /// (default popup background read foreign on Leaf canvas). Renders as a
    /// LeafColor.surface.inset pill with `L4`/`L5` short label + chevron;
    /// click reveals the long-form choices in a native Menu.
    @ViewBuilder
    private func granularityMenu(_ folder: WatchedFolder) -> some View {
        Menu {
            Button("L4 — folder only") {
                service.update(id: folder.id, granularity: .L4)
            }
            Button("L5 — file names") {
                service.update(id: folder.id, granularity: .L5)
            }
        } label: {
            HStack(spacing: LeafSpace.xs) {
                Text(folder.maxGranularity == .L4 ? "L4 — folder only" : "L5 — file names")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LeafColor.text.tertiary)
            }
            .padding(.horizontal, LeafSpace.sm)
            .padding(.vertical, LeafSpace.xs)
            .background(
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(LeafColor.surface.inset)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
