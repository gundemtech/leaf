//
//  TokensTypeSection.swift
//  Track 2 / D1 — Preview rows for LeafType.* font tokens.
//

import SwiftUI

#if DEBUG
struct TokensTypeSection: View {
    private let samples: [(String, Font, String)] = [
        ("display.large", LeafType.display.large, "SF Pro Display · 64 · semibold · -0.02em"),
        ("display.regular", LeafType.display.regular, "SF Pro Display · 48 · semibold · -0.02em"),
        ("title.large", LeafType.title.large, "SF Pro Display · 28 · semibold · -0.01em"),
        ("title.medium", LeafType.title.medium, "SF Pro Display · 22 · semibold"),
        ("title.small", LeafType.title.small, "SF Pro Text · 17 · semibold"),
        ("body.large", LeafType.body.large, "SF Pro Text · 17 · regular"),
        ("body.regular", LeafType.body.regular, "SF Pro Text · 15 · regular"),
        ("body.small", LeafType.body.small, "SF Pro Text · 13 · regular"),
        ("caption", LeafType.caption, "SF Pro Text · 12 · regular"),
        ("mono.regular", LeafType.mono.regular, "SF Mono · 14 · regular"),
        ("mono.small", LeafType.mono.small, "SF Mono · 12 · regular"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.lg) {
            Text("Typography").font(LeafType.title.large).foregroundStyle(LeafColor.text.primary)
            ForEach(samples, id: \.0) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.0).font(LeafType.mono.small).foregroundStyle(LeafColor.text.tertiary)
                        .frame(width: 140, alignment: .leading)
                    Text("Sample text").font(entry.1).foregroundStyle(LeafColor.text.primary)
                    Spacer(minLength: LeafSpace.lg)
                    Text(entry.2).font(LeafType.mono.small).foregroundStyle(LeafColor.text.quaternary)
                }
                .padding(.vertical, LeafSpace.xs)
            }
            Text("LABEL").leafSectionLabel().foregroundStyle(LeafColor.text.secondary)
        }
    }
}
#endif
