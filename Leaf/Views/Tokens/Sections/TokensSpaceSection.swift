//
//  TokensSpaceSection.swift
//  Track 2 / D1 — Preview ladder for LeafSpace.* spacing scale.
//

import SwiftUI

#if DEBUG
struct TokensSpaceSection: View {
    private let scale: [(String, CGFloat)] = [
        ("xxs", LeafSpace.xxs), ("xs", LeafSpace.xs), ("sm", LeafSpace.sm),
        ("md", LeafSpace.md), ("lg", LeafSpace.lg), ("xl", LeafSpace.xl),
        ("xxl", LeafSpace.xxl), ("xxxl", LeafSpace.xxxl),
        ("xxxxl", LeafSpace.xxxxl), ("xxxxxl", LeafSpace.xxxxxl),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Spacing").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            ForEach(scale, id: \.0) { item in
                HStack(spacing: LeafSpace.md) {
                    Text(item.0)
                        .font(LeafType.mono.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                        .frame(width: 60, alignment: .leading)
                    Rectangle()
                        .fill(LeafColor.accent.primary)
                        .frame(width: item.1, height: LeafSpace.lg)
                    Text("\(Int(item.1))pt")
                        .font(LeafType.mono.small)
                        .foregroundStyle(LeafColor.text.secondary)
                }
            }
        }
    }
}
#endif
