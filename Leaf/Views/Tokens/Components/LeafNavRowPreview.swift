//
//  LeafNavRowPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O3 LeafNavRow.
//

import SwiftUI

#if DEBUG
struct LeafNavRowPreview: View {
    @State private var homeSelected = true
    @State private var teamSelected = false
    @State private var settingsSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafNavRow").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                LeafNavRow(
                    icon: "house",
                    title: "Home",
                    isSelected: $homeSelected,
                    onTap: {
                        homeSelected = true
                        teamSelected = false
                        settingsSelected = false
                    }
                )
                LeafNavRow(
                    icon: "person.2",
                    title: "Team",
                    badge: 3,
                    isSelected: $teamSelected,
                    onTap: {
                        homeSelected = false
                        teamSelected = true
                        settingsSelected = false
                    }
                )
                LeafNavRow(
                    icon: "gearshape",
                    title: "Settings",
                    shortcut: "⌘,",
                    isSelected: $settingsSelected,
                    onTap: {
                        homeSelected = false
                        teamSelected = false
                        settingsSelected = true
                    }
                )
            }
            .frame(width: 240)

            TokensInlineSpec(
                spec: "LeafNavRow · 36pt height · rest/hover/selected · accent.subtle bg selected · LeafBadge + LeafKeyboardShortcut slots",
                codeSnippet: "LeafNavRow(icon: \"house\", title: \"Home\", isSelected: $sel) { tap() }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
