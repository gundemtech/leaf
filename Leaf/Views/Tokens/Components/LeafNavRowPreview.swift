//
//  LeafNavRowPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O3 LeafNavRow. Renders the
//  full Sidebar set so every nav glyph is visible in the design system.
//

import SwiftUI

#if DEBUG
struct LeafNavRowPreview: View {
    @State private var selected: WindowSection = .home

    private let rows: [(WindowSection, Int?, String?)] = [
        (.home, nil, nil),
        (.activity, 5, nil),
        (.team, 3, nil),
        (.connections, nil, nil),
        (.organization, nil, nil),
        (.settings, nil, "⌘,"),
        (.profile, nil, nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafNavRow").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.xxs) {
                ForEach(rows, id: \.0) { tuple in
                    let section = tuple.0
                    LeafNavRow(
                        icon: section.iconIsSystem ? .system(section.icon) : .asset(section.icon),
                        title: section.title,
                        badge: tuple.1,
                        shortcut: tuple.2,
                        isSelected: Binding(
                            get: { selected == section },
                            set: { _ in selected = section }
                        ),
                        onTap: { selected = section }
                    )
                }
            }
            .frame(width: 240)

            TokensInlineSpec(
                spec:
                    "LeafNavRow · 36pt height · rest/hover/selected · accent.subtle bg selected · LeafBadge + LeafKeyboardShortcut slots · icon (asset|system)",
                codeSnippet: "LeafNavRow(icon: .asset(LeafIcons.nav.home), title: \"Home\", isSelected: $sel) { tap() }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
