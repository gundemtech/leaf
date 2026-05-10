//
//  LeafBadgeTokens.swift
//  Track 2 / D1 — T3 tokens for LeafBadge.
//

import SwiftUI

enum LeafBadgeTokens {
    enum Variant { case neutral, accent, numeric }

    /// Minimum square size for numeric badges — guarantees a single-digit
    /// badge renders as a circle, not a flattened pill. Width grows past
    /// this value naturally as digits are added.
    static let numericMinSize: CGFloat = 18
}
