//
//  LeafNavRowTokens.swift
//  Track 2 / D1 — T3 tokens for LeafNavRow. Fixed height (36pt) and corner
//  radius (LeafRadius.md). States rest/hover/selected resolved inline at
//  consume site via @State + @Binding flags.
//

import CoreGraphics

enum LeafNavRowTokens {
    static let height:       CGFloat = 36
    static let cornerRadius: CGFloat = LeafRadius.md
}
