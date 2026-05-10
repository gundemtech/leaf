//
//  LeafWindowLayoutPreview.swift
//  Track 2 / D1 — TokensPreview entry for Template T1 LeafWindowLayout.
//  Inline preview uses scaled mock content so the full split-view fits.
//

import SwiftUI

#if DEBUG
struct LeafWindowLayoutPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafWindowLayout").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            LeafWindowLayout(
                sidebar: {
                    VStack(alignment: .leading, spacing: LeafSpace.xs) {
                        Text("Workspace")
                            .font(LeafType.label)
                            .foregroundStyle(LeafColor.text.tertiary)
                        ForEach(["Activity", "Team", "Connections", "Settings"], id: \.self) { name in
                            Text(name)
                                .font(LeafType.body.regular)
                                .foregroundStyle(LeafColor.text.primary)
                                .padding(.vertical, LeafSpace.xs)
                        }
                    }
                },
                detail: {
                    VStack(alignment: .leading, spacing: LeafSpace.lg) {
                        Text("Activity")
                            .font(LeafType.title.large)
                            .foregroundStyle(LeafColor.text.primary)
                        LeafMetricAmbient(value: "27", label: "events today")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            )
            .frame(width: 900, height: 520)
            .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
            .scaleEffect(0.45, anchor: .topLeading)
            .frame(width: 900 * 0.45, height: 520 * 0.45)

            TokensInlineSpec(
                spec: "LeafWindowLayout · NavigationSplitView · sidebar 220/260/320 · detail padding xl · canvas bg",
                codeSnippet: "LeafWindowLayout(sidebar: { ... }, detail: { ... })"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
