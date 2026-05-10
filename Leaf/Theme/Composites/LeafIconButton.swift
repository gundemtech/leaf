//
//  LeafIconButton.swift
//  Track 2 / D1 — Molecule M2. Square icon-only button. Shares LeafButtonTokens
//  (Variant + Size). Frame is square (size.height × size.height); icon point
//  size derived as 0.45 × height for visual parity with text buttons at the
//  same Size. Two render paths — SF Symbol (`systemName:`) and Asset Catalog
//  (`asset:`) custom Figma SVG.
//

import SwiftUI

struct LeafIconButton: View {
    private enum Source {
        case system(String)
        case asset(String)
    }

    private let source: Source
    var variant: LeafButtonTokens.Variant = .ghost
    var size: LeafButtonTokens.Size = .md
    let action: () -> Void

    init(systemName: String,
         variant: LeafButtonTokens.Variant = .ghost,
         size: LeafButtonTokens.Size = .md,
         action: @escaping () -> Void) {
        self.source = .system(systemName)
        self.variant = variant
        self.size = size
        self.action = action
    }

    init(asset: String,
         variant: LeafButtonTokens.Variant = .ghost,
         size: LeafButtonTokens.Size = .md,
         action: @escaping () -> Void) {
        self.source = .asset(asset)
        self.variant = variant
        self.size = size
        self.action = action
    }

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            iconView
                .foregroundStyle(LeafButtonTokens.Foreground.resting(variant))
                .frame(width: size.height, height: size.height)
                .background(
                    RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous)
                        .fill(isHovering
                              ? LeafButtonTokens.Background.hover(variant)
                              : LeafButtonTokens.Background.resting(variant))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .leafAnimation(LeafMotion.spring.snappy, value: isHovering)
    }

    @ViewBuilder
    private var iconView: some View {
        let pt = size.height * 0.45
        switch source {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: pt, weight: .regular))
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: pt, height: pt)
        }
    }
}
