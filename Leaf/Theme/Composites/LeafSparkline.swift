//
//  LeafSparkline.swift
//  Track 2 / D1 — Metric MT4. Minimal trend stroke. No axis, no labels, no
//  animation — values are normalised over the available frame and rendered
//  as a single rounded-cap path. Empty / single-point inputs degrade to an
//  empty path (no crash).
//

import SwiftUI

struct LeafSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let xStep = geo.size.width / CGFloat(values.count - 1)
                let minV = values.min() ?? 0
                let maxV = values.max() ?? 1
                let range = max(maxV - minV, 0.0001)
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * xStep
                    let normalized = (v - minV) / range
                    let y = geo.size.height * (1 - CGFloat(normalized))
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(
                LeafMetricTokens.Sparkline.color,
                style: StrokeStyle(
                    lineWidth: LeafMetricTokens.Sparkline.strokeWidth,
                    lineCap:  .round,
                    lineJoin: .round
                )
            )
        }
        .frame(minHeight: LeafMetricTokens.Sparkline.minHeight)
    }
}
