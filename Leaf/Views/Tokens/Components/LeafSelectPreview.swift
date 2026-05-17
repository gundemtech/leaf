//
//  LeafSelectPreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M7 LeafSelect.
//

import SwiftUI

#if DEBUG
private struct PreviewOption: Hashable, Identifiable {
    let id: Int
    let title: String
}

private let previewOptions: [PreviewOption] = [
    .init(id: 0, title: "Dev"),
    .init(id: 1, title: "PM"),
    .init(id: 2, title: "Designer"),
]

struct LeafSelectPreview: View {
    @State private var dropdown = previewOptions[0]
    @State private var combobox = previewOptions[1]
    @State private var segmented = previewOptions[2]

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafSelect").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                LeafSelect(selection: $dropdown, variant: .dropdown, options: previewOptions) { Text($0.title) }
                LeafSelect(selection: $combobox, variant: .combobox, options: previewOptions) { Text($0.title) }
                LeafSelect(selection: $segmented, variant: .segmented, options: previewOptions) { Text($0.title) }
            }

            TokensInlineSpec(
                spec: "LeafSelect · dropdown / combobox / segmented · tint LeafColor.accent.primary",
                codeSnippet: "LeafSelect(selection: $value, variant: .dropdown, options: opts) { Text($0.title) }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
