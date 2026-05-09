//
//  LeafRadius.swift
//  Track 2 / D1 — Tier 2 corner radii.
//

import CoreGraphics

enum LeafRadius {
    static let sm:  CGFloat = 6
    static let md:  CGFloat = 10
    static let lg:  CGFloat = 14
    static let xl:  CGFloat = 20
    static let xxl: CGFloat = 28
    static let pill: CGFloat = 999
    /// Window-native radius — macOS 26+ derives automatically; pre-26 fallback
    /// uses 18pt (matches NSWindow standard `kCGSWindowMinSize` aesthetic).
    static let window: CGFloat = 18
}
