//
//  LeafTabPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O9 LeafTab.
//

import SwiftUI

#if DEBUG
private enum LeafTabPreviewSection: String, CaseIterable, Identifiable, Hashable {
    case overview, analytics, presence, settings
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct LeafTabPreview: View {
    @State private var selection: LeafTabPreviewSection = .analytics

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafTab")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            LeafTab(
                selection: $selection,
                tabs: LeafTabPreviewSection.allCases,
                label: { $0.label }
            )

            Text("Selected: \(selection.label)")
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.tertiary)

            TokensInlineSpec(
                spec:
                    "LeafTab · generic <Tab: Hashable & Identifiable> · underline indicator on selected · spring.gentle move",
                codeSnippet: "LeafTab(selection: $tab, tabs: Section.allCases, label: { $0.label })"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
