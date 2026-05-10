//
//  LeafIconChip.swift
//  Track 2 / D1 — Atom A5. Tinted squircle holding a centered glyph. Gives
//  iconography presence on a surface (banners, list rows, status callouts)
//  without bleeding tone into the whole row. Sizes sm/md/lg pair the outer
//  square with the matching LeafIcon scale.
//
//  Tint applies to the glyph; background defaults to `tint` at
//  LeafIconChipTokens.defaultBackgroundOpacity, but consumers can pass an
//  explicit background for cases where the tone tint is unrelated to the
//  surface fill (e.g. neutral muted chip on a dark surface).
//

import SwiftUI

struct LeafIconChip: View {
    let asset: String
    var size: LeafIconChipTokens.Size = .md
    var tint: Color = LeafColor.text.primary
    var background: Color? = nil

    var body: some View {
        let bg = background ?? tint.opacity(LeafIconChipTokens.defaultBackgroundOpacity)
        return ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(bg)
            LeafIcon(asset: asset, size: size.icon, tint: tint)
        }
        .frame(width: size.outer, height: size.outer)
    }
}
