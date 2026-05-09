//
//  LeafKeyboardShortcut.swift
//  Track 2 / D1 — Molecule M10. Renders a keyboard hint badge (e.g. "⌘⌥T")
//  with monospaced font and subtle bg/border. No T3 file.
//
//  Spec/plan calls for a 1pt vertical pad — token guard rejects raw int
//  paddings, so we use LeafSpace.xxs (2pt). Visual delta is negligible.
//

import SwiftUI

struct LeafKeyboardShortcut: View {
    let glyphs: String

    var body: some View {
        Text(glyphs)
            .font(LeafType.mono.small)
            .foregroundStyle(LeafColor.text.tertiary)
            .padding(.horizontal, LeafSpace.xs)
            .padding(.vertical, LeafSpace.xxs)
            .background(
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .fill(LeafColor.surface.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LeafRadius.sm, style: .continuous)
                    .strokeBorder(LeafColor.border.subtle, lineWidth: 1)
            )
    }
}
