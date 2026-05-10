//
//  LeafMetricTokens.swift
//  Track 2 / D1 — T3 tokens shared by MT1..MT4 metric primitives + MetricCard
//  organism. Created by Task 35 with the Inline subgroup; extended in Tasks 36
//  (Ambient), 37 (Delta), 38 (Sparkline), and post-D1 metric redesign (Delta
//  pill chrome, Sparkline gradient + terminal dot, MetricCard chrome).
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

    /// Directional delta — pill chrome with direction-tinted background.
    /// Foreground colour follows direction (success / danger / tertiary).
    enum Delta {
        static let upColor:   Color   = LeafColor.status.success
        static let downColor: Color   = LeafColor.status.danger
        static let flatColor: Color   = LeafColor.text.tertiary
        static let arrowSize: CGFloat = 10
        /// Capsule background = direction colour at this opacity. Matches
        /// LeafPillTokens.Tone.success/danger conventions (0.12).
        static let bgOpacity: CGFloat = 0.12
        /// Flat direction has no useful colour, so its capsule uses neutral inset.
        static let flatBackground: Color = LeafColor.surface.inset
    }

    /// Sparkline — minimal trend stroke + soft area fill + terminal dot.
    /// Gradient fill anchors the line to a baseline so the visual reads as a
    /// completed shape, not a floating polyline. Terminal dot signals "current
    /// value" — useful when the chart sits next to a delta pill.
    enum Sparkline {
        static let strokeWidth: CGFloat = 1.5
        static let color:       Color   = LeafColor.accent.primary
        static let minHeight:   CGFloat = 24
        /// Gradient stops for the area fill below the stroke.
        static let gradientTopOpacity:    CGFloat = 0.18
        static let gradientBottomOpacity: CGFloat = 0.0
        /// Diameter of the filled circle marker at the last data point.
        static let terminalDotSize: CGFloat = 4
    }

    /// Card chrome composed by LeafMetricCard. Background = surface.raised,
    /// corner radius LeafRadius.lg, raised elevation.
    enum Card {
        static let padding:         CGFloat = LeafSpace.lg
        static let titleValueGap:   CGFloat = LeafSpace.md
        static let valueDeltaGap:   CGFloat = LeafSpace.sm
        static let sparklineHeight: CGFloat = 40
    }
}
