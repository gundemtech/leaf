//
//  LeafMetricInlinePreview.swift
//  Track 2 / D1 — TokensPreview entry for Metric MT1 LeafMetricInline.
//  Demonstrates narrative integration: numbers sit on the same baseline as
//  surrounding body text, distinguished by tabular figures + primary tone.
//

import SwiftUI

#if DEBUG
struct LeafMetricInlinePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafMetricInline").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(alignment: .leading, spacing: LeafSpace.md) {
                HStack(alignment: .firstTextBaseline, spacing: LeafSpace.xs) {
                    Text("Сегодня focus:")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.secondary)
                    LeafMetricInline(value: "4h 32m")
                    Text("overall")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: LeafSpace.xs) {
                    Text("Commits this week:")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.secondary)
                    LeafMetricInline(value: "27")
                }

                HStack(alignment: .firstTextBaseline, spacing: LeafSpace.xs) {
                    Text("Context switches:")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.secondary)
                    LeafMetricInline(value: "8")
                    Text("/ hour")
                        .font(LeafType.body.regular)
                        .foregroundStyle(LeafColor.text.tertiary)
                }
            }

            TokensInlineSpec(
                spec: "LeafMetricInline · body.regular · monospaced digits · text.primary · narrative-baseline",
                codeSnippet: "LeafMetricInline(value: \"4h 32m\")"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
