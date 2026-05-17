//
//  LeafSpace.swift
//  Track 2 / D1 — Tier 2 spacing scale, 4pt baseline. UI consumers use
//  LeafSpace.* instead of raw integer values; guard fails on .padding(<int>).
//
//  Spec uses 3xl/4xl/5xl labels — Swift identifiers cannot start with a digit,
//  so we use xxxl/xxxxl/xxxxxl. Mapping:
//    spec 3xl → xxxl  (48pt)
//    spec 4xl → xxxxl (64pt)
//    spec 5xl → xxxxxl (96pt)
//

import CoreGraphics

enum LeafSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
    static let xxxxl: CGFloat = 64
    static let xxxxxl: CGFloat = 96
}
