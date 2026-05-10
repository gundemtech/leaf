//
//  LeafIconLabel.swift
//  Track 2 / D1 — Molecule M9. Horizontal icon + text with alignment slot
//  (leading / centered / trailing). Accepts SF Symbol (`systemName:`) or
//  Asset Catalog (`asset:`) glyph.
//

import SwiftUI

enum LeafIconLabelAlignment {
    case leading, centered, trailing
}

struct LeafIconLabel: View {
    enum IconRef {
        case system(String)
        case asset(String)
    }

    let icon: IconRef
    let title: String
    var alignment: LeafIconLabelAlignment = .leading
    var iconTint: Color = LeafColor.text.secondary
    var titleStyle: Font = LeafType.body.regular

    var body: some View {
        HStack(spacing: LeafSpace.sm) {
            if alignment == .trailing { Spacer() }
            if alignment == .centered { Spacer() }
            iconView
            Text(title).font(titleStyle).foregroundStyle(LeafColor.text.primary)
            if alignment == .centered { Spacer() }
            if alignment == .leading { Spacer() }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .system(let name):
            LeafIcon(systemName: name, size: .md, tint: iconTint)
        case .asset(let name):
            LeafIcon(asset: name, size: .md, tint: iconTint)
        }
    }
}
