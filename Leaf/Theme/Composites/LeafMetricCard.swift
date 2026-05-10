//
//  LeafMetricCard.swift
//  Track 2 / D1 — Organism. Card-chromed metric tile composing existing
//  primitives (Ambient number + Delta pill + Sparkline) on a surface.raised
//  rounded chrome with raised elevation. Optional title row carries an
//  optional fresh-data dot at trailing.
//
//  Layout (vertical, single column):
//      ┌─ LeafSpace.lg padding ───────────────────┐
//      │  title                            ●      │  ← optional, body.small tertiary + LeafDot
//      │                                          │
//      │  4h 32m   ╭ ↗ +12% ╮                    │  ← display number + delta pill (firstTextBaseline)
//      │           ╰────────╯                    │
//      │                                          │
//      │  ╱╲   ╱╲                                 │  ← optional sparkline (40pt height)
//      │ ╱  ╲_╱  ╲╱╲                              │
//      └──────────────────────────────────────────┘
//
//  Composition over inheritance — card takes primitive value types (String,
//  Delta, [Double]) rather than nested Views so call-sites stay declarative
//  and the card owns its hierarchy / spacing.
//

import SwiftUI

struct LeafMetricCard: View {
    /// Inline delta spec — keeps the card API value-typed instead of nesting
    /// a LeafMetricDelta view.
    struct Delta {
        let value: String
        let direction: LeafDeltaDirection
    }

    let title: String?
    let value: String
    let delta: Delta?
    let sparklineValues: [Double]?
    let isFresh: Bool

    init(title: String? = nil,
         value: String,
         delta: Delta? = nil,
         sparklineValues: [Double]? = nil,
         isFresh: Bool = false) {
        self.title = title
        self.value = value
        self.delta = delta
        self.sparklineValues = sparklineValues
        self.isFresh = isFresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LeafMetricTokens.Card.titleValueGap) {
            if let title {
                HStack(spacing: LeafSpace.xs) {
                    Text(title)
                        .font(LeafType.body.small)
                        .foregroundStyle(LeafColor.text.tertiary)
                    Spacer(minLength: 0)
                    if isFresh {
                        LeafDot(tone: .accent, size: .sm)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: LeafMetricTokens.Card.valueDeltaGap) {
                Text(value)
                    .font(LeafMetricTokens.Ambient.valueFont)
                    .foregroundStyle(LeafColor.text.primary)
                if let delta {
                    LeafMetricDelta(value: delta.value, direction: delta.direction)
                }
            }

            if let sparklineValues, sparklineValues.count > 1 {
                LeafSparkline(
                    values: sparklineValues,
                    tint: delta?.direction.color ?? LeafMetricTokens.Sparkline.color
                )
                .frame(height: LeafMetricTokens.Card.sparklineHeight)
            }
        }
        .padding(LeafMetricTokens.Card.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous)
                .fill(LeafColor.surface.raised)
        )
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
        .leafElevation(LeafElevation.raised)
    }
}
