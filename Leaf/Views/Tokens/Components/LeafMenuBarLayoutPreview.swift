//
//  LeafMenuBarLayoutPreview.swift
//  Track 2 / D1 — TokensPreview entry for Template T3 LeafMenuBarLayout.
//

import SwiftUI

#if DEBUG
struct LeafMenuBarLayoutPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.sm) {
            Text("LeafMenuBarLayout").font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            LeafMenuBarLayout {
                VStack(alignment: .leading, spacing: LeafSpace.sm) {
                    HStack {
                        Text("Leaf")
                            .font(LeafType.title.small)
                            .foregroundStyle(LeafColor.text.primary)
                        Spacer()
                        Text("v0.1")
                            .font(LeafType.mono.small)
                            .foregroundStyle(LeafColor.text.tertiary)
                    }
                    LeafDivider()
                    ForEach(["Open dashboard", "Pause sharing", "Settings…", "Quit"], id: \.self) { item in
                        Text(item)
                            .font(LeafType.body.regular)
                            .foregroundStyle(LeafColor.text.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, LeafSpace.xs)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LeafRadius.md, style: .continuous))

            TokensInlineSpec(
                spec: "LeafMenuBarLayout · fixed width 360 · padding md · surface.raised bg",
                codeSnippet: "LeafMenuBarLayout { content }"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
