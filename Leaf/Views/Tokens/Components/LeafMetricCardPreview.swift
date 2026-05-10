//
//  LeafMetricCardPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism LeafMetricCard.
//

import SwiftUI

#if DEBUG
struct LeafMetricCardPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafMetricCard").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            // 3-up grid emulation — common dashboard pattern.
            HStack(alignment: .top, spacing: LeafSpace.md) {
                LeafMetricCard(
                    title: "Focus today",
                    value: "4h 32m",
                    delta: .init(value: "+12%", direction: .up),
                    sparklineValues: [3, 4, 6, 5, 7, 9, 11, 12],
                    isFresh: true
                )
                LeafMetricCard(
                    title: "Commits this week",
                    value: "27",
                    delta: .init(value: "+5", direction: .up),
                    sparklineValues: [1, 3, 2, 5, 4, 7, 6, 9]
                )
                LeafMetricCard(
                    title: "Context switches / hr",
                    value: "8",
                    delta: .init(value: "−4%", direction: .down),
                    sparklineValues: [12, 10, 11, 7, 6, 5, 4, 2]
                )
            }

            // Reduced layouts — number-only and number+delta (no sparkline).
            HStack(alignment: .top, spacing: LeafSpace.md) {
                LeafMetricCard(
                    title: "Active integrations",
                    value: "3"
                )
                LeafMetricCard(
                    title: "Deep-work streak",
                    value: "5d",
                    delta: .init(value: "0%", direction: .flat)
                )
                LeafMetricCard(
                    value: "94%",
                    delta: .init(value: "+1%", direction: .up),
                    sparklineValues: [82, 85, 88, 90, 92, 91, 93, 94]
                )
            }

            TokensInlineSpec(
                spec: "LeafMetricCard · surface.raised · LeafRadius.lg · raised elevation · optional title row + fresh ● · ambient + delta + sparkline slots",
                codeSnippet: "LeafMetricCard(title: \"Focus\", value: \"4h 32m\", delta: .init(value: \"+12%\", direction: .up), sparklineValues: [...])"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
