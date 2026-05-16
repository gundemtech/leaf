//
//  LeafFeedRowTokens.swift
//  Track 5 / S7 B.4 — T3 tokens for LeafFeedRow. Row height + icon size +
//  grouped-expand spacing + chevron rotation angle + expand animation.
//

import SwiftUI

enum LeafFeedRowTokens {
    static let rowHeight: CGFloat = 36
    static let iconSize: CGFloat = 14
    static let groupedExpandedSpacing: CGFloat = LeafSpace.xs
    static let chevronRotation: Angle = .degrees(90)  // when expanded
    static let expandAnimation: Animation = .easeInOut(duration: 0.15)
}
