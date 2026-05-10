//
//  LeafMetricAmbientPreview.swift
//  Track 2 / D1 — TokensPreview entry for Metric MT2 LeafMetricAmbient.
//

import SwiftUI

#if DEBUG
struct LeafMetricAmbientPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafMetricAmbient").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            HStack(alignment: .top, spacing: LeafSpace.xxl) {
                LeafMetricAmbient(value: "4h 32m", label: "focus today")
                LeafMetricAmbient(value: "27",     label: "commits this week")
                LeafMetricAmbient(value: "8",      label: "context switches / hr")
            }

            TokensInlineSpec(
                spec: "LeafMetricAmbient · display.regular monospaced digits · body.small tertiary label · no card chrome",
                codeSnippet: "LeafMetricAmbient(value: \"4h 32m\", label: \"focus today\")"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
