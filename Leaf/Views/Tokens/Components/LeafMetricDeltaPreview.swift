//
//  LeafMetricDeltaPreview.swift
//  Track 2 / D1 — TokensPreview entry for Metric MT3 LeafMetricDelta.
//

import SwiftUI

#if DEBUG
struct LeafMetricDeltaPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafMetricDelta").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            HStack(spacing: LeafSpace.xl) {
                LeafMetricDelta(value: "+12%", direction: .up)
                LeafMetricDelta(value: "−4%",  direction: .down)
                LeafMetricDelta(value: "0%",   direction: .flat)
            }

            HStack(alignment: .firstTextBaseline, spacing: LeafSpace.md) {
                LeafMetricInline(value: "27 commits")
                LeafMetricDelta(value: "+5", direction: .up)
            }

            TokensInlineSpec(
                spec: "LeafMetricDelta · directions up/down/flat · status.success/danger · text.tertiary · arrowSize 11",
                codeSnippet: "LeafMetricDelta(value: \"+12%\", direction: .up)"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
