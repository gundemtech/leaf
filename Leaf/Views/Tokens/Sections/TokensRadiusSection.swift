//
//  TokensRadiusSection.swift
//  Track 2 / D1 — Preview tiles for LeafRadius.* corner radii.
//

import SwiftUI

#if DEBUG
struct TokensRadiusSection: View {
    private let scale: [(String, CGFloat)] = [
        ("sm", LeafRadius.sm), ("md", LeafRadius.md), ("lg", LeafRadius.lg),
        ("xl", LeafRadius.xl), ("xxl", LeafRadius.xxl), ("pill", LeafRadius.pill),
        ("window", LeafRadius.window),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Radii").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            HStack(spacing: LeafSpace.lg) {
                ForEach(scale, id: \.0) { item in
                    VStack(spacing: LeafSpace.xs) {
                        RoundedRectangle(cornerRadius: item.1, style: .continuous)
                            .fill(LeafColor.surface.raised)
                            .overlay(
                                RoundedRectangle(cornerRadius: item.1, style: .continuous)
                                    .strokeBorder(LeafColor.border.strong, lineWidth: 1)
                            )
                            .frame(width: LeafSpace.xxxxl, height: LeafSpace.xxxxl)
                        Text(item.0).font(LeafType.mono.small).foregroundStyle(LeafColor.text.tertiary)
                    }
                }
            }
        }
    }
}
#endif
