//
//  LeafMetricDelta.swift
//  Track 2 / D1 — Metric MT3. Directional delta as a tinted pill: green up /
//  red down / muted flat. Capsule chrome with direction-coloured foreground +
//  same colour at low opacity for the background (mirrors LeafPill.success
//  / .danger conventions). Used to express change vs. prior period.
//

import SwiftUI

enum LeafDeltaDirection {
    case up, down, flat

    /// Foreground (icon + text) colour.
    var color: Color {
        switch self {
        case .up:   LeafMetricTokens.Delta.upColor
        case .down: LeafMetricTokens.Delta.downColor
        case .flat: LeafMetricTokens.Delta.flatColor
        }
    }

    /// Capsule background tint. Up/down derive from the foreground colour at
    /// low opacity; flat falls back to neutral surface.inset (no useful tint).
    var background: Color {
        switch self {
        case .up:   LeafMetricTokens.Delta.upColor.opacity(LeafMetricTokens.Delta.bgOpacity)
        case .down: LeafMetricTokens.Delta.downColor.opacity(LeafMetricTokens.Delta.bgOpacity)
        case .flat: LeafMetricTokens.Delta.flatBackground
        }
    }

    /// Asset Catalog name (template-rendered Figma SVG) for the directional arrow.
    var arrow: String {
        switch self {
        case .up:   LeafIcons.metric.up
        case .down: LeafIcons.metric.down
        case .flat: LeafIcons.metric.flat
        }
    }
}

struct LeafMetricDelta: View {
    let value: String
    let direction: LeafDeltaDirection

    var body: some View {
        HStack(spacing: LeafSpace.xxs) {
            Image(direction.arrow)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: LeafMetricTokens.Delta.arrowSize,
                       height: LeafMetricTokens.Delta.arrowSize)
            Text(value)
                .font(LeafType.body.small.monospacedDigit())
        }
        .foregroundStyle(direction.color)
        .padding(.horizontal, LeafSpace.xs)
        .padding(.vertical, LeafSpace.xxs)
        .background(Capsule().fill(direction.background))
    }
}
