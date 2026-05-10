//
//  LeafMetricDelta.swift
//  Track 2 / D1 — Metric MT3. Directional delta with intentional discipline:
//  green up / red down / tertiary flat. Used to express change vs. prior period.
//

import SwiftUI

enum LeafDeltaDirection {
    case up, down, flat

    var color: Color {
        switch self {
        case .up:   LeafMetricTokens.Delta.upColor
        case .down: LeafMetricTokens.Delta.downColor
        case .flat: LeafMetricTokens.Delta.flatColor
        }
    }

    var arrow: String {
        switch self {
        case .up:   "arrow.up"
        case .down: "arrow.down"
        case .flat: "arrow.right"
        }
    }
}

struct LeafMetricDelta: View {
    let value: String
    let direction: LeafDeltaDirection

    var body: some View {
        HStack(spacing: LeafSpace.xxs) {
            Image(systemName: direction.arrow)
                .font(.system(size: LeafMetricTokens.Delta.arrowSize))
            Text(value)
                .font(LeafType.body.small.monospacedDigit())
        }
        .foregroundStyle(direction.color)
    }
}
