//
//  LeafMetricTokens.swift
//  Track 2 / D1 — T3 tokens shared by MT1..MT4 metric primitives.
//  Created by Task 35 with the Inline subgroup; extended incrementally
//  in Tasks 36 (Ambient), 37 (Delta), 38 (Sparkline).
//

import SwiftUI

enum LeafMetricTokens {
    /// Inline metric — same baseline as surrounding text but tabular figures.
    enum Inline {
        static let font: Font = LeafType.body.regular.monospacedDigit()
        static let foreground: Color = LeafColor.text.primary
    }
}
