//
//  LeafIconPreview.swift
//  Track 2 / D1 — TokensPreview entry for Atom A1 LeafIcon. Demonstrates both
//  render paths: SF Symbol (`systemName:`) and Asset Catalog (`asset:`).
//

import SwiftUI

#if DEBUG
struct LeafIconPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafIcon").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)
            HStack(spacing: LeafSpace.lg) {
                LeafIcon(asset: LeafIcons.brand.leafFill, size: .sm)
                LeafIcon(asset: LeafIcons.brand.leafFill, size: .md)
                LeafIcon(asset: LeafIcons.brand.leafFill, size: .lg)
                LeafIcon(asset: LeafIcons.brand.leafFill, size: .md, tint: LeafColor.accent.primary)
                LeafIcon(asset: LeafIcons.brand.leafFill, size: .md, tint: LeafColor.status.danger)
                LeafDivider()
                LeafIcon(systemName: "magnifyingglass", size: .md)
            }
            TokensInlineSpec(
                spec: "LeafIcon · sm/md/lg · tint via LeafColor.* · asset (Figma SVG) | systemName (SF)",
                codeSnippet: "LeafIcon(asset: LeafIcons.brand.leafFill, size: .md, tint: LeafColor.accent.primary)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
