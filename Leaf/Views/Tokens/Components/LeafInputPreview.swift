//
//  LeafInputPreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M6 LeafInput.
//

import SwiftUI

#if DEBUG
struct LeafInputPreview: View {
    @State private var rest = ""
    @State private var withIcon = "leaf"
    @State private var withError = "bad@"
    @State private var disabled = "read-only"
    @State private var lg = ""

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafInput").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.sm) {
                LeafInput(text: $rest, placeholder: "Rest (md)")
                LeafInput(text: $withIcon, placeholder: "With prefix icon", prefixIcon: "magnifyingglass")
                LeafInput(text: $withError, placeholder: "Email", error: "Enter a valid email")
                LeafInput(text: $disabled, placeholder: "Disabled", disabled: true)
                LeafInput(text: $lg, placeholder: "Large (lg)", size: .lg)
            }

            TokensInlineSpec(
                spec: "LeafInput · md(36)/lg(44) · rest/focus/error/disabled · prefix icon · radius LeafRadius.md",
                codeSnippet: "LeafInput(text: $text, placeholder: \"Email\", error: \"Invalid\")"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
