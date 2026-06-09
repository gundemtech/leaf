//
//  WhatsNewView.swift
//  Phase 3 — in-app "What's New" sheet. Renders the current release's notes
//  (highlighted) plus a collapsible history of prior releases, from the bundled
//  release-notes catalog (releases.json). Pure presentation — the caller marks the
//  version seen on dismiss (so a closed/back-grounded window never loses the present).
//

import SwiftUI
import LeafCore

struct WhatsNewView: View {
    let catalog: ReleaseNotesCatalog
    let currentVersion: String

    @Environment(\.dismiss) private var dismiss

    /// The release to highlight: the running build's entry, else the newest.
    private var current: ReleaseNote? {
        catalog.release(version: currentVersion) ?? catalog.latest
    }

    /// Everything except the highlighted release, newest-first (the catalog order).
    private var history: [ReleaseNote] {
        guard let cur = current else { return [] }
        return catalog.releases.filter { $0.version != cur.version }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LeafColor.border.subtle)
            ScrollView {
                VStack(alignment: .leading, spacing: LeafSpace.xl) {
                    if let cur = current {
                        releaseBlock(cur, showHeader: false)
                    } else {
                        Text("No release notes available.")
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.secondary)
                    }
                    if !history.isEmpty {
                        previousReleases
                    }
                }
                .padding(LeafSpace.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 560)
        .background(LeafColor.surface.canvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                Text("What's New")
                    .font(LeafType.title.medium)
                    .foregroundStyle(LeafColor.text.primary)
                if let cur = current {
                    Text("Leaf \(cur.version) · \(cur.date)")
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(LeafSpace.xl)
    }

    @ViewBuilder
    private func releaseBlock(_ note: ReleaseNote, showHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            if showHeader {
                Text("\(note.version) · \(note.date)")
                    .font(LeafType.body.regular)
                    .foregroundStyle(LeafColor.text.primary)
            }
            notesSection("Added", note.added)
            notesSection("Fixed", note.fixed)
            notesSection("Changed", note.changed)
            if !note.hasNotes {
                Text("No notable changes.")
                    .font(LeafType.body.small)
                    .foregroundStyle(LeafColor.text.tertiary)
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: LeafSpace.xs) {
                Text(title)
                    .font(LeafType.label)
                    .foregroundStyle(LeafColor.accent.primary)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: LeafSpace.xs) {
                        Text("•").foregroundStyle(LeafColor.text.tertiary)
                        Text(item)
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var previousReleases: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: LeafSpace.lg) {
                ForEach(history) { note in
                    releaseBlock(note, showHeader: true)
                }
            }
            .padding(.top, LeafSpace.sm)
        } label: {
            Text("Previous releases")
                .font(LeafType.body.regular)
                .foregroundStyle(LeafColor.text.primary)
        }
    }
}
