//
//  LeafToolbarPreview.swift
//  Track 2 / D1 — TokensPreview entry for Organism O8 LeafToolbar.
//

import SwiftUI

#if DEBUG
struct LeafToolbarPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: LeafSpace.md) {
            Text("LeafToolbar")
                .font(LeafType.title.medium)
                .foregroundStyle(LeafColor.text.primary)

            VStack(spacing: LeafSpace.md) {
                LeafToolbar(
                    leading: {
                        LeafIconButton(asset: LeafIcons.nav.sidebar, variant: .ghost, size: .sm, action: {})
                    },
                    center: {
                        Text("Activity")
                            .font(LeafType.title.small)
                            .foregroundStyle(LeafColor.text.primary)
                    },
                    trailing: {
                        HStack(spacing: LeafSpace.xs) {
                            LeafIconButton(systemName: LeafIcons.nav.searchSF, variant: .ghost, size: .sm, action: {})
                            LeafIconButton(systemName: LeafIcons.nav.filterSF, variant: .ghost, size: .sm, action: {})
                        }
                    }
                )

                LeafToolbar(
                    leading: {
                        Text("Team")
                            .font(LeafType.title.small)
                            .foregroundStyle(LeafColor.text.primary)
                    },
                    center: { EmptyView() },
                    trailing: {
                        LeafButton("Invite", variant: .primary, size: .sm, action: {})
                    }
                )
            }

            TokensInlineSpec(
                spec: "LeafToolbar · leading/center/trailing slots · canvas bg · bottom hairline",
                codeSnippet: "LeafToolbar(leading: { … }, center: { … }, trailing: { … })"
            )
        }
        .padding(LeafSpace.lg)
        .background(LeafColor.surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: LeafRadius.lg, style: .continuous))
    }
}
#endif
