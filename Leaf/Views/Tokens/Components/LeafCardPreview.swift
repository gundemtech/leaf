//
//  LeafCardPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O1 LeafCard.
//

import SwiftUI

#if DEBUG
struct LeafCardPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafCard").font(LeafType.title.medium).foregroundStyle(LeafColor.text.primary)

            // Side-by-side variant comparison — same content shape so chrome
            // differences read directly.
            HStack(alignment: .top, spacing: LeafSpace.md) {
                LeafCard(variant: .rest) {
                    sampleContent(label: "rest", caption: "no fill, hairline only")
                }
                LeafCard(variant: .raised) {
                    sampleContent(label: "raised", caption: "surface.raised + floating elevation")
                }
                LeafCard(variant: .glass) {
                    sampleContent(label: "glass", caption: ".leafGlass(.regular)")
                }
            }

            // Full slot example — header + content + footer.
            LeafCard(
                variant: .raised,
                padding: .generous,
                header: {
                    VStack(alignment: .leading, spacing: LeafSpace.xs) {
                        Text("Focus this week")
                            .font(LeafType.title.medium)
                            .foregroundStyle(LeafColor.text.primary)
                        Text("Aggregate of all watched apps · Mon–Sun")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                },
                content: {
                    VStack(alignment: .leading, spacing: LeafSpace.sm) {
                        HStack(alignment: .firstTextBaseline, spacing: LeafSpace.md) {
                            Text("28h 41m")
                                .font(LeafMetricTokens.Ambient.valueFont)
                                .foregroundStyle(LeafColor.text.primary)
                            LeafMetricDelta(value: "+12%", direction: .up)
                        }
                        LeafSparkline(values: [3, 4, 6, 5, 7, 9, 11, 12])
                            .frame(height: 40)
                    }
                },
                footer: {
                    HStack(spacing: LeafSpace.xs) {
                        LeafBadge(text: "v0.1", variant: .neutral)
                        Text("· updated 2 min ago")
                            .font(LeafType.body.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                        Spacer(minLength: 0)
                        LeafButton("Open report", variant: .ghost, size: .sm) {}
                    }
                }
            )

            TokensInlineSpec(
                spec: "LeafCard · rest/raised/glass · padding tight/regular/generous · LeafColor.border.subtle hairline · raised → floating elevation · header→content sm gap · content→footer lg gap",
                codeSnippet: "LeafCard(variant: .raised, padding: .regular) { Text(\"…\") }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func sampleContent(label: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: LeafSpace.xs) {
            Text(label)
                .font(LeafType.title.small)
                .foregroundStyle(LeafColor.text.primary)
            Text(caption)
                .font(LeafType.body.small)
                .foregroundStyle(LeafColor.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
