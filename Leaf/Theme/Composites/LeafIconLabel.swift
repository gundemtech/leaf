//
//  LeafIconLabel.swift
//  Track 2 / D1 — Molecule M9. Horizontal icon + text with alignment slot
//  (leading / centered / trailing). No T3 file — alignment exposed inline.
//

import SwiftUI

enum LeafIconLabelAlignment {
    case leading, centered, trailing
}

struct LeafIconLabel: View {
    let icon: String
    let title: String
    var alignment: LeafIconLabelAlignment = .leading
    var iconTint: Color = LeafColor.text.secondary
    var titleStyle: Font = LeafType.body.regular

    var body: some View {
        HStack(spacing: LeafSpace.sm) {
            if alignment == .trailing { Spacer() }
            if alignment == .centered { Spacer() }
            LeafIcon(systemName: icon, size: .md, tint: iconTint)
            Text(title).font(titleStyle).foregroundStyle(LeafColor.text.primary)
            if alignment == .centered { Spacer() }
            if alignment == .leading { Spacer() }
        }
    }
}
