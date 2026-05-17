//
//  LeafKeyboardShortcutPreview.swift
//  Track 2 / D1 — TokensPreview entry for Molecule M10 LeafKeyboardShortcut.
//

import SwiftUI

#if DEBUG
struct LeafKeyboardShortcutPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafKeyboardShortcut").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            HStack(spacing: LeafSpace.sm) {
                LeafKeyboardShortcut(glyphs: "⌘⌥T")
                LeafKeyboardShortcut(glyphs: "⌘K")
                LeafKeyboardShortcut(glyphs: "⌘⇧P")
                LeafKeyboardShortcut(glyphs: "⌃⌘F")
                LeafKeyboardShortcut(glyphs: "Esc")
            }

            TokensInlineSpec(
                spec:
                    "LeafKeyboardShortcut · LeafType.mono.small · LeafColor.surface.inset bg · subtle border · radius sm",
                codeSnippet: "LeafKeyboardShortcut(glyphs: \"⌘⌥T\")"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
