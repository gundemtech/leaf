//
//  TokensElevationSection.swift
//  Track 2 / D1 — Preview tiles for LeafElevation.* shadow tokens.
//

import SwiftUI

#if DEBUG
struct TokensElevationSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Elevation").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            HStack(spacing: LeafSpace.xl) {
                tile("flat", LeafElevation.flat)
                tile("raised", LeafElevation.raised)
                tile("floating", LeafElevation.floating)
                tile("modal", LeafElevation.modal)
            }
        }
    }

    private func tile(_ name: String, _ shadow: LeafElevation.Shadow) -> some View {
        VStack(spacing: LeafSpace.sm) {
            RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous)
                .fill(LeafColor.surface.raised)
                .frame(width: LeafSpace.xxxxl, height: LeafSpace.xxxxl)
                .leafElevation(shadow)
            Text(name).font(LeafType.mono.small).foregroundStyle(LeafColor.text.tertiary)
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.canvas)
    }
}
#endif
