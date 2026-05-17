//
//  LeafSparklinePreview.swift
//  Track 2 / D1 — TokensPreview entry for Metric MT4 LeafSparkline.
//

import SwiftUI

#if DEBUG
struct LeafSparklinePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafSparkline").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.md) {
                row(
                    label: "rising",
                    values: [3, 4, 6, 5, 7, 9, 11, 12])
                row(
                    label: "falling",
                    values: [12, 10, 11, 7, 6, 5, 4, 2])
                row(
                    label: "spiky",
                    values: [4, 4, 12, 4, 9, 4, 11, 4])
                row(
                    label: "flat",
                    values: [6, 6, 6, 6, 6, 6, 6, 6])
                row(
                    label: "single (degenerate)",
                    values: [5])
            }

            HStack(alignment: .center, spacing: LeafSpace.md) {
                LeafMetricAmbient(value: "27", label: "commits")
                LeafSparkline(values: [1, 3, 2, 5, 4, 7, 6, 9])
                    .frame(width: 80, height: 32)
                LeafMetricDelta(value: "+8", direction: .up)
            }

            TokensInlineSpec(
                spec:
                    "LeafSparkline · Catmull-Rom smoothed · accent.primary stroke 1.5pt + 0.18→0 gradient area fill + 4pt terminal dot · static path · minHeight 24",
                codeSnippet: "LeafSparkline(values: [1, 3, 2, 5, 4, 7, 6, 9])"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func row(label: String, values: [Double]) -> some View {
        HStack(spacing: LeafSpace.md) {
            Text(label)
                .font(LeafType.mono.small)
                .foregroundStyle(LeafColor.text.tertiary)
                .frame(width: 160, alignment: .leading)
            LeafSparkline(values: values)
                .frame(height: 32)
        }
    }
}
#endif
