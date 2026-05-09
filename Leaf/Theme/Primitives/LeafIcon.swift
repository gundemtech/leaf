//
//  LeafIcon.swift
//  Track 2 / D1 — Atom A1. SF Symbol wrapper with size variant + tint via T2 colour.
//  No T3 file (atom — T2 sufficient).
//

import SwiftUI

enum LeafIconSize {
    case sm, md, lg
    var pt: CGFloat {
        switch self {
        case .sm: 12
        case .md: 16
        case .lg: 24
        }
    }
}

struct LeafIcon: View {
    let systemName: String
    var size: LeafIconSize = .md
    var tint: Color = LeafColor.text.primary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size.pt, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size.pt, height: size.pt)
    }
}
