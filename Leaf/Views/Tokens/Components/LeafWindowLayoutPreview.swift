//
//  LeafWindowLayoutPreview.swift
//  Track 2 / D1 — TokensPreview entry for Template T1 LeafWindowLayout.
//  NavigationSplitView is window-root by design and does not embed cleanly
//  at sub-window scale, so the inline preview is a static mockup that
//  diagrams the layout (sidebar + divider + detail) using the same tokens.
//  Production usage stays identical to the codeSnippet below.
//

import SwiftUI

#if DEBUG
struct LeafWindowLayoutPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafWindowLayout").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            HStack(spacing: 0) {
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
                    Spacer()
                }
                .padding(.horizontal, LeafSpace.sm)
                .padding(.vertical, LeafSpace.md)
                .frame(width: 160)
                .frame(maxHeight: .infinity)
                .background(LeafColor.surface.canvas)

                Rectangle()
                    .fill(LeafColor.border.subtle)
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: LeafSpace.lg) {
                    Text("Activity")
                        .font(LeafType.title.large)
                        .foregroundStyle(LeafColor.text.primary)
                    LeafMetricAmbient(value: "27", label: "events today")
                    Spacer()
                }
                .padding(LeafSpace.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(LeafColor.surface.canvas)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))

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
