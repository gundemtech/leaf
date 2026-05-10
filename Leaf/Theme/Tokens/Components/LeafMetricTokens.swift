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

    /// Ambient metric — large quiet display number paired with a tertiary label.
    /// No card chrome; sits directly on canvas.
    enum Ambient {
        static let valueFont: Font = LeafType.display.regular.monospacedDigit()
        static let labelFont: Font = LeafType.body.small
        static let labelTracking: CGFloat = 0
    }

    /// Directional delta — colour follows direction; arrow size surfaced as a
    /// token so the symbol weight is tunable without code edits.
    enum Delta {
        static let upColor:   Color   = LeafColor.status.success
        static let downColor: Color   = LeafColor.status.danger
        static let flatColor: Color   = LeafColor.text.tertiary
        static let arrowSize: CGFloat = 11
    }

    /// Sparkline — minimal trend stroke. Static path, no axis, no labels.
    /// minHeight surfaced as a token so layout sizing is one-line tunable.
    enum Sparkline {
        static let strokeWidth: CGFloat = 1.5
        static let color:       Color   = LeafColor.accent.primary
        static let minHeight:   CGFloat = 24
    }
}
