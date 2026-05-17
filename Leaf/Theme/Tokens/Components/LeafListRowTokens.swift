//
//  LeafListRowTokens.swift
//  Track 2 / D1 — T3 tokens for LeafListRow. Padding presets + corner radius;
//  height 52pt is a guideline (plan §2701) — actual height derives from
//  padding + content (2-line text layout fits under 52pt with these values).
//

import CoreGraphics

enum LeafListRowTokens {
    static let horizontalPadding: CGFloat = LeafSpace.md
    static let verticalPadding: CGFloat = LeafSpace.sm
    static let cornerRadius: CGFloat = LeafRadius.md
}
