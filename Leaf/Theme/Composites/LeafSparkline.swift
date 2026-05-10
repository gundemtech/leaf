//
//  LeafSparkline.swift
//  Track 2 / D1 — Metric MT4. Smoothed trend line + soft area fill + terminal
//  dot. Path is a uniform Catmull-Rom spline through the data points (converted
//  to cubic Bézier segments) so inflections read as soft curves, not folded
//  corners. The closed area below the stroke is filled with a vertical
//  gradient (accent.primary opacity 0.18 → 0.0) which anchors the line to a
//  baseline so the visual reads as a completed shape, not a floating polyline.
//  Empty / single-point inputs degrade to nothing rendered (no crash).
//

import SwiftUI

struct LeafSparkline: View {
    let values: [Double]
    /// Tint applied to stroke, gradient fill, and terminal dot. Default is
    /// accent.primary; consumers (e.g. LeafMetricCard) override to match the
    /// associated delta direction so a falling metric reads as danger, not
    /// accent.
    var tint: Color = LeafMetricTokens.Sparkline.color

    var body: some View {
        GeometryReader { geo in
            let points = points(in: geo.size)
            ZStack {
                if points.count > 1 {
                    // Area fill — same smoothed curve, closed to baseline.
                    smoothedPath(points, closeAtBottom: geo.size.height)
                        .fill(
                            LinearGradient(
                                colors: [
                                    tint.opacity(LeafMetricTokens.Sparkline.gradientTopOpacity),
                                    tint.opacity(LeafMetricTokens.Sparkline.gradientBottomOpacity)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Stroke.
                    smoothedPath(points, closeAtBottom: nil)
                        .stroke(
                            tint,
                            style: StrokeStyle(
                                lineWidth: LeafMetricTokens.Sparkline.strokeWidth,
                                lineCap:  .round,
                                lineJoin: .round
                            )
                        )

                    // Terminal dot at last point — current-value marker.
                    if let last = points.last {
                        Circle()
                            .fill(tint)
                            .frame(width: LeafMetricTokens.Sparkline.terminalDotSize,
                                   height: LeafMetricTokens.Sparkline.terminalDotSize)
                            .position(x: last.x, y: last.y)
                    }
                }
            }
        }
        .frame(minHeight: LeafMetricTokens.Sparkline.minHeight)
    }

    /// Normalises `values` into screen-space points. Returns empty array on
    /// empty / single-point input (degenerate cases the renderer skips).
    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let xStep = size.width / CGFloat(values.count - 1)
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let range = max(maxV - minV, 0.0001)
        return values.enumerated().map { i, v in
            let x = CGFloat(i) * xStep
            let normalized = (v - minV) / range
            let y = size.height * (1 - CGFloat(normalized))
            return CGPoint(x: x, y: y)
        }
    }

    /// Builds a smoothed path through `points` using uniform Catmull-Rom
    /// converted to cubic Bézier segments (control points = ±(p[i+1]-p[i-1])/6,
    /// boundary points clamped). When `closeAtBottom` is non-nil, the path is
    /// closed down to that y-coordinate at first and last x — used for the
    /// area-fill gradient.
    private func smoothedPath(_ points: [CGPoint], closeAtBottom: CGFloat?) -> Path {
        Path { path in
            guard points.count >= 2 else { return }

            if let bottomY = closeAtBottom {
                path.move(to: CGPoint(x: points[0].x, y: bottomY))
                path.addLine(to: points[0])
            } else {
                path.move(to: points[0])
            }

            for i in 0..<(points.count - 1) {
                let p0 = i == 0 ? points[0] : points[i - 1]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]

                let cp1 = CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6,
                    y: p1.y + (p2.y - p0.y) / 6
                )
                let cp2 = CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6,
                    y: p2.y - (p3.y - p1.y) / 6
                )
                path.addCurve(to: p2, control1: cp1, control2: cp2)
            }

            if let bottomY = closeAtBottom, let last = points.last {
                path.addLine(to: CGPoint(x: last.x, y: bottomY))
                path.closeSubpath()
            }
        }
    }
}
