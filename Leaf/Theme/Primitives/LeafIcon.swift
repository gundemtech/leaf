//
//  LeafIcon.swift
//  Track 2 / D1 — Atom A1. Glyph wrapper with size variant + tint via T2 colour.
//  Two render paths:
//    • SF Symbol (`systemName:`) — used for system glyphs we don't override
//      (search / filter, plus any future SF-only callsites).
//    • Asset Catalog (`asset:`) — template-rendered SVGs from the Figma
//      design system, surfaced via the `LeafIcons.*` namespace.
//

import SwiftUI

enum LeafIconSize {
    case sm, md, lg, xl
    var pt: CGFloat {
        switch self {
        case .sm: 12
        case .md: 16
        case .lg: 24
        case .xl: 32
        }
    }
}

private enum LeafIconSource {
    case system(String)
    case asset(String)
}

struct LeafIcon: View {
    private let source: LeafIconSource
    private let size: LeafIconSize
    private let tint: Color

    init(systemName: String, size: LeafIconSize = .md, tint: Color = LeafColor.text.primary) {
        self.source = .system(systemName)
        self.size = size
        self.tint = tint
    }

    init(asset: String, size: LeafIconSize = .md, tint: Color = LeafColor.text.primary) {
        self.source = .asset(asset)
        self.size = size
        self.tint = tint
    }

    var body: some View {
        Group {
            switch source {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: size.pt, weight: .regular))
            case .asset(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .foregroundStyle(tint)
        .frame(width: size.pt, height: size.pt)
    }
}
