//
//  LeafIconChip.swift
//  Track 2 / D1 — Atom A5. Tinted squircle holding a centered glyph. Gives
//  iconography presence on a surface (banners, list rows, status callouts)
//  without bleeding tone into the whole row. Sizes sm/md/lg pair the outer
//  square with the matching LeafIcon scale.
//
//  Two glyph sources, matching the LeafIcon primitive:
//    • asset:      Asset-Catalog template SVG (default — Figma design system)
//    • systemName: SF Symbol (fallback for state-specific glyphs not yet
//                  designed in Figma; pattern matches LeafIconButton).
//
//  Tint applies to the glyph; background defaults to `tint` at
//  LeafIconChipTokens.defaultBackgroundOpacity, but consumers can pass an
//  explicit background for cases where the tone tint is unrelated to the
//  surface fill (e.g. neutral muted chip on a dark surface).
//

import SwiftUI

struct LeafIconChip: View {
    private let source: Source
    let size: LeafIconChipTokens.Size
    let tint: Color
    let background: Color?

    private enum Source {
        case asset(String)
        case systemName(String)
    }

    init(
        asset: String,
        size: LeafIconChipTokens.Size = .md,
        tint: Color = LeafColor.text.primary,
        background: Color? = nil
    ) {
        self.source = .asset(asset)
        self.size = size
        self.tint = tint
        self.background = background
    }

    init(
        systemName: String,
        size: LeafIconChipTokens.Size = .md,
        tint: Color = LeafColor.text.primary,
        background: Color? = nil
    ) {
        self.source = .systemName(systemName)
        self.size = size
        self.tint = tint
        self.background = background
    }

    var body: some View {
        let bg = background ?? tint.opacity(LeafIconChipTokens.defaultBackgroundOpacity)
        return ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(bg)
            glyph
        }
        .frame(width: size.outer, height: size.outer)
    }

    @ViewBuilder
    private var glyph: some View {
        switch source {
        case .asset(let name):
            LeafIcon(asset: name, size: size.icon, tint: tint)
        case .systemName(let name):
            LeafIcon(systemName: name, size: size.icon, tint: tint)
        }
    }
}
